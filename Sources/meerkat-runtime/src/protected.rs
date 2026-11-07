//! The file system rule code reaches through Deno's APIs (`Deno.*`,
//! `node:fs`): the real one, except that nothing may change a protected path
//! or anything at, inside or above it, nor read at or inside one protected
//! from reading too (the daemon's state).
//!
//! Deno's own deny list cannot hold this. It compares the path a call names,
//! with `..` resolved but no symlink, and it lets a call act on a directory
//! above a denied path. So a symlink into the rules folder from a granted
//! folder, a rules folder that is itself reached through a symlink, or
//! renaming one of the rules folder's ancestors away and another into its
//! place, would each let a rule with a write grant rewrite rules and
//! `meerkat.json`, and through them widen its own grants. Here every
//! changing call is checked against real paths, resolved when it runs: the
//! entry it names (its folder's real path, plus its name) and what that
//! entry leads to when it is a symlink. A call that changes a file's
//! contents is refused, too, for a file with more than one hard link, which
//! may be a protected file under another name. Every call that reads a path
//! (opening it, listing it, its metadata, where it leads) is checked the
//! same way against the paths protected from reading: Deno's deny list for
//! reads compares text too, so a symlink in a read grant would reach the
//! state folder through it.
//!
//! A real path here is the one the kernel names (`resolve`), so a folder's
//! other names (a firmlink's under the data volume, `/.nofollow/…`,
//! `/.vol/…`) reach nothing a protected path's own name would not, and
//! paths are compared without case, as APFS compares them by default.
//!
//! A protected path is held by every name it has on the way to what it
//! names: as named, by each symlink it passes through (as the entry that
//! link is), and by where it leads. So neither the folder a protected path
//! is named in, nor a link on its way, nor the folder it leads to, can be
//! renamed or removed, which would let a folder of the rule's own take its
//! place.
//!
//! The check and the call resolve the path apart, so a folder renamed
//! between them could send the call somewhere the check never saw. Each
//! checked call holds `NAMESPACE` from its check to its end, a rename
//! holding it alone, so no rule's rename lands between another call's check
//! and that call; an async call checks on the blocking pool, just before it
//! acts. None waits on another program while it holds it: files are opened
//! without blocking (a FIFO's other end, a port's carrier), and only
//! regular files are copied. Renaming is the only way rule code changes
//! where a path leads: it cannot make symlinks (Deno lets only code with
//! every permission, and `node:fs`'s `cp`, which would copy one, is off),
//! and this refuses moving a symlink that leads into a protected path, and
//! hard links to protected files.
//!
//! A file opened only to read cannot have its mode, owner or times changed
//! through its descriptor either (`GuardedFile`): `node:fs`'s `fchmod`,
//! `fchown` and `futimes`, and `Deno.FsFile`'s `utime`, act on the open file
//! without coming back here.
//!
//! The daemon's effects that act on a path (`files.trash`,
//! `files.setTags`) check it and act holding `NAMESPACE` alone too
//! (lib.rs, `hold_rule_renames`).
//!
//! What this does not see: a link made, or a path swapped, by another
//! program between the check and the call (docs/design/meerkatd.md, "Known
//! limits"). Deno APIs that write or watch outside this trait are off: ops
//! in worker.rs (`UNGUARDED_WRITE_OPS`, `UNGUARDED_READ_OPS`), native classes
//! in js/runtime.js (`refuseUnguardedWrites`).

use std::borrow::Cow;
use std::ffi::OsString;
use std::io;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::rc::Rc;
use std::sync::{Arc, LazyLock, Mutex, PoisonError, RwLock};

use deno_core::futures::future::{self, LocalBoxFuture};
use deno_core::unsync::spawn_blocking;
use deno_core::{BufMutView, BufView, ResourceHandleFd, WriteOutcome};
use deno_runtime::deno_fs::sync::new_rc;
use deno_runtime::deno_fs::{
    FileSystem, FsDirEntry, FsError, FsFileType, FsReadDir, FsReadDirRc, OpenOptions, RealFs,
    open_options_for_checked_path,
};
use deno_runtime::deno_io::StdFileResourceInner;
use deno_runtime::deno_io::fs::{File, FsResult, FsStat, FsStatFs};
use deno_runtime::deno_permissions::{CheckedPath, CheckedPathBuf, OpenAccessKind};
use rustix::fs::{Mode, OFlags};

/// What every call goes to. A static, so an async call's future may borrow
/// it for as long as the call runs.
static REAL: RealFs = RealFs;

/// Held by every checked call of every worker from its check to its end:
/// shared, or alone by a rename, which is what could make a checked path lead
/// elsewhere. One for the process, since the files are.
static NAMESPACE: RwLock<()> = RwLock::new(());

/// Symlinks followed from one path before giving up, as the kernel's
/// `MAXSYMLINKS`.
const MAXIMUM_LINKS: usize = 32;

/// `ELOOP` (`<sys/errno.h>`), which an `O_NOFOLLOW` open of a symlink fails
/// with.
const ELOOP: i32 = 62;
/// `ENOENT`, which `RealFs` reports such an open as.
const ENOENT: i32 = 2;
/// `O_NONBLOCK` (`<sys/fcntl.h>`), as `OpenOptions::custom_flags` takes it.
const O_NONBLOCK: i32 = 0x4;

/// The paths no rule's code may change (the file's `deny_write`), and those
/// it may not read either (its `deny_read`), as the daemon names them.
/// Replaced on each permit; resolved on each check, so a folder moved or
/// linked later is still found.
#[derive(Debug, Default)]
pub struct Protected(Mutex<Lists>);

#[derive(Debug, Default)]
struct Lists {
    write: Vec<PathBuf>,
    read: Vec<PathBuf>,
}

impl Protected {
    pub fn set(&self, write: &[String], read: &[String]) {
        let paths = |paths: &[String]| paths.iter().map(PathBuf::from).collect();
        *self.0.lock().unwrap() = Lists { write: paths(write), read: paths(read) };
    }

    /// Each path of a list in every form it has (`forms`), `folded`.
    fn real_forms(&self, list: impl FnOnce(&Lists) -> &Vec<PathBuf>) -> Vec<PathBuf> {
        let named = list(&self.0.lock().unwrap()).clone();
        named.iter().flat_map(|path| forms(path)).map(|form| folded(&form)).collect()
    }

    /// Whether a change to what any of `forms` (`folded`) names is at,
    /// inside or above a path protected from changing.
    fn changes_protected(&self, forms: &[&Path]) -> bool {
        self.real_forms(|lists| &lists.write)
            .iter()
            .any(|protected| forms.iter().any(|form| form.starts_with(protected) || protected.starts_with(form)))
    }

    fn check(&self, path: &Path, access: Access) -> FsResult<()> {
        let named = entry(path);
        let leads_to = followed(&named);
        let (entry, target) = (folded(&named), folded(&leads_to));
        if access == Access::Read {
            // Reading above a protected path (listing the folder that holds
            // it) shows only its name, so only at or inside one is refused.
            for protected in self.real_forms(|lists| &lists.read) {
                if [&entry, &target].iter().any(|form| form.starts_with(&protected)) {
                    return Err(refused(path, "is a protected path of meerkatd, or inside one"));
                }
            }
            return Ok(());
        }
        if self.changes_protected(&[&entry, &target]) {
            return Err(refused(path, "is a protected path of meerkatd, or inside or above one"));
        }
        if access == Access::Contents
            && let Ok(metadata) = std::fs::metadata(&leads_to)
            && metadata.is_file()
            && metadata.nlink() > 1
        {
            return Err(refused(path, "has more than one hard link, so it may be a protected file of meerkatd"));
        }
        Ok(())
    }
}

/// What a call does with a path: reads it or what it leads to, or changes
/// the directory entry it names (create, remove, rename), or also the
/// contents of the file the entry leads to.
#[derive(Clone, Copy, PartialEq)]
enum Access {
    Read,
    Entry,
    Contents,
}

/// How a checked call holds `NAMESPACE`.
#[derive(Clone, Copy)]
enum Hold {
    Shared,
    Renaming,
}

/// `call`, holding `NAMESPACE` as `hold` says. A poisoned lock guards
/// nothing of its own, so it is taken as it is.
fn held<T>(hold: Hold, call: impl FnOnce() -> FsResult<T>) -> FsResult<T> {
    match hold {
        Hold::Shared => {
            let _held = NAMESPACE.read().unwrap_or_else(PoisonError::into_inner);
            call()
        }
        Hold::Renaming => holding_renames(call),
    }
}

/// `work`, holding `NAMESPACE` alone: no rule's code renames anything, or is
/// between a changing call's check and its end, until it returns. The
/// daemon's own path effects run so too (lib.rs, `hold_rule_renames`).
pub(crate) fn holding_renames<T>(work: impl FnOnce() -> T) -> T {
    let _held = NAMESPACE.write().unwrap_or_else(PoisonError::into_inner);
    work()
}

#[derive(Debug)]
pub struct GuardedFs {
    protected: Arc<Protected>,
}

impl GuardedFs {
    pub fn new(protected: Arc<Protected>) -> Self {
        GuardedFs { protected }
    }

    /// `call` once each of `checks` passes, holding `NAMESPACE` from the
    /// first check to the end of the call.
    fn checked<T>(&self, hold: Hold, checks: &[(&Path, Access)], call: impl FnOnce() -> FsResult<T>) -> FsResult<T> {
        held(hold, || {
            for (path, access) in checks {
                self.protected.check(path, *access)?;
            }
            call()
        })
    }

    /// `checked` on the blocking pool, for an async call: checked there,
    /// just before the call, not when rule code made it, so nothing rule code
    /// does in between goes unseen.
    fn checked_async<'b, T: Send + 'static>(
        &self,
        hold: Hold,
        checks: Vec<(PathBuf, Access)>,
        call: impl FnOnce() -> FsResult<T> + Send + 'static,
    ) -> LocalBoxFuture<'b, FsResult<T>> {
        let protected = self.protected.clone();
        let work = move || {
            held(hold, || {
                for (path, access) in &checks {
                    protected.check(path, *access)?;
                }
                call()
            })
        };
        Box::pin(async move { spawn_blocking(work).await? })
    }
}

/// What an open is checked as: a read, and a change of the file's contents
/// when it may make one.
fn opening(path: &Path, changes: bool) -> Vec<(&Path, Access)> {
    let mut checks = vec![(path, Access::Read)];
    if changes {
        checks.push((path, Access::Contents));
    }
    checks
}

/// A folder's entries, read whole on the blocking pool once its check
/// passed, then handed out one at a time.
#[derive(Debug)]
struct Listed(Mutex<std::vec::IntoIter<FsDirEntry>>);

impl FsReadDir for Listed {
    fn next<'s, 't>(&'s self) -> LocalBoxFuture<'t, FsResult<Option<FsDirEntry>>>
    where
        's: 't,
        Self: 't,
    {
        let next = self.0.lock().unwrap().next();
        Box::pin(future::ready(Ok(next)))
    }
}

/// Whether an open may change the file: write, append, create or truncate.
fn writes(options: OpenOptions) -> bool {
    options.access_kind() != OpenAccessKind::Read
}

/// What `RealFs` opens, as a `std` file, which can come back from the
/// blocking pool where an `Rc<dyn File>` cannot. As `RealFs` does: `std`
/// will not create a file it does not open to write, so a read that may
/// create makes the file first; and a path Deno resolved is opened
/// `O_NOFOLLOW`, so a symlink found there is one whose target went away.
///
/// Unlike `RealFs`, opened without blocking, then made blocking again unless
/// the caller asked otherwise: the open runs holding `NAMESPACE`, and one
/// that waits (a FIFO for its other end, a serial port for its carrier)
/// would hold off every rule's renames and the daemon's path effects for as
/// long. A FIFO opened to write with no reader fails (`ENXIO`) instead.
fn open_std(path: &CheckedPath, options: OpenOptions) -> FsResult<std::fs::File> {
    let asked = options.custom_flags.unwrap_or(0);
    let open = |options: OpenOptions| {
        let options = OpenOptions { custom_flags: Some(options.custom_flags.unwrap_or(0) | O_NONBLOCK), ..options };
        match open_options_for_checked_path(options, path).open(path) {
            Err(error) if path.canonicalized() && error.raw_os_error() == Some(ELOOP) => {
                Err(io::Error::from_raw_os_error(ENOENT))
            }
            opened => opened,
        }
    };
    let file = if options.create && !options.write && !options.append {
        if !path.exists() {
            let create = OpenOptions {
                read: false,
                write: true,
                create: true,
                truncate: false,
                append: false,
                create_new: options.create_new,
                custom_flags: None,
                mode: options.mode,
            };
            drop(open(create)?);
        }
        open(OpenOptions { read: true, custom_flags: options.custom_flags, ..OpenOptions::default() })?
    } else {
        open(options)?
    };
    if asked & O_NONBLOCK == 0 {
        let flags = rustix::fs::fcntl_getfl(&file).map_err(io::Error::from)?;
        rustix::fs::fcntl_setfl(&file, flags.difference(OFlags::NONBLOCK)).map_err(io::Error::from)?;
    }
    Ok(file)
}

/// Copying opens the source to read, and only a regular file's open never
/// waits: a FIFO's waits for a writer, holding `NAMESPACE` (`open_std`).
fn regular(path: &Path) -> FsResult<()> {
    if std::fs::metadata(path)?.is_file() {
        return Ok(());
    }
    Err(FsError::Io(io::Error::new(io::ErrorKind::InvalidInput, format!("{} is not a regular file", path.display()))))
}

fn refused(path: &Path, why: &str) -> FsError {
    FsError::Io(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} {why}", path.display())))
}

/// `path` as the kernel names it, as `canonicalPath` in `MeerkatKit` does:
/// the real path of its longest existing ancestor, with that ancestor's
/// deepest directory named as the kernel names it once open (`F_GETPATH`),
/// joined with the rest. `canonicalize` (`realpath`) alone leaves other
/// names of one folder standing: since macOS 10.15 the data volume's folders
/// are reached at their firmlinks (`/Users`) and under the volume's mount
/// point (`/System/Volumes/Data/Users`), and `/.nofollow/…` and
/// `/.vol/<device>/<inode>` name any file again. The kernel's name is one of
/// them whichever was used.
fn resolve(path: &Path) -> PathBuf {
    let path = deno_core::normalize_path(Cow::Borrowed(path)).into_owned();
    let mut rest = Vec::new();
    let mut current = path.as_path();
    let real = loop {
        if let Ok(real) = std::fs::canonicalize(current) {
            break real;
        }
        match (current.parent(), current.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                current = parent;
            }
            _ => return path,
        }
    };
    // A directory that cannot be opened (no read permission) is named
    // through the nearest one above it that can: below a folder's kernel
    // name, the rest are plain names.
    let mut directory = real.as_path();
    let named = loop {
        if let Some(named) = kernel_name(directory) {
            break named;
        }
        match (directory.parent(), directory.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                directory = parent;
            }
            _ => break directory.to_owned(),
        }
    };
    rest.iter().rev().fold(named, |path, name| path.join(name))
}

/// The kernel's name for the directory at `path`, or `None` when it is not a
/// directory or cannot be opened. Opened without blocking, so a FIFO swapped
/// in is refused rather than waited on.
fn kernel_name(path: &Path) -> Option<PathBuf> {
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NONBLOCK | OFlags::CLOEXEC;
    let directory = rustix::fs::open(path, flags, Mode::empty()).ok()?;
    let name = rustix::fs::getpath(&directory).ok()?;
    Some(PathBuf::from(OsString::from_vec(name.into_bytes())))
}

/// The entry `path` names: what it reaches, as the kernel names it, unless
/// it is a symlink, which is the entry itself, not what it points to: then
/// its folder's real path and its own name. (Naming every other entry as
/// the kernel does keeps `~/LIBRARY` from passing as some other folder than
/// `~/Library`.)
fn entry(path: &Path) -> PathBuf {
    let path = deno_core::normalize_path(Cow::Borrowed(path)).into_owned();
    let link = std::fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink());
    match (path.parent(), path.components().next_back()) {
        (Some(parent), Some(Component::Normal(name))) if link => resolve(parent).join(name),
        _ => resolve(&path),
    }
}

/// Every form of a protected `path`, as `CapabilityGrants.forms` in the
/// daemon gives them (`protected_cases.json` holds both to the same verdicts):
/// as named, each symlink it passes through on the way (`links_along`), and
/// what it resolves to, each with its names on the data volume.
fn forms(path: &Path) -> Vec<PathBuf> {
    let named = deno_core::normalize_path(Cow::Borrowed(path)).into_owned();
    let mut real = links_along(&named);
    real.push(resolve(&named));
    let volume: Vec<PathBuf> = real.iter().flat_map(|form| data_volume_names(form)).collect();
    [named].into_iter().chain(real).chain(volume).collect()
}

/// The symlinks an absolute `path` passes through, the last part's
/// included, each as the entry it is (`entry`), followed as the kernel
/// follows them; at most `MAXIMUM_LINKS`. Below a part that does not exist,
/// nothing is a link.
fn links_along(path: &Path) -> Vec<PathBuf> {
    enum Part {
        Up,
        Name(OsString),
    }
    let parts = |path: &Path| {
        path.components()
            .filter_map(|part| match part {
                Component::ParentDir => Some(Part::Up),
                Component::Normal(name) => Some(Part::Name(name.to_owned())),
                Component::RootDir | Component::CurDir | Component::Prefix(_) => None,
            })
            .collect::<Vec<_>>()
    };
    // What is left to walk, last part first; `current` is real throughout.
    let mut pending: Vec<Part> = parts(path).into_iter().rev().collect();
    let mut current = PathBuf::from("/");
    let mut links = Vec::new();
    while let Some(part) = pending.pop() {
        let name = match part {
            Part::Up => {
                current.pop();
                continue;
            }
            Part::Name(name) => name,
        };
        let candidate = current.join(&name);
        match std::fs::read_link(&candidate) {
            Ok(target) if links.len() < MAXIMUM_LINKS => {
                links.push(entry(&candidate));
                if target.is_absolute() {
                    current = PathBuf::from("/");
                }
                pending.extend(parts(&target).into_iter().rev());
            }
            _ => current = candidate,
        }
    }
    links
}

/// The data volume's names for a resolved `path`: under its mount point
/// (`/System/Volumes/Data/Users/…` for `/Users/…`), for each firmlink in
/// `/usr/share/firmlinks` that `path` is at or inside, as `dataVolumeNames`
/// in `MeerkatKit`. The kernel names such a folder by its firmlink, so
/// `resolve` never returns these, but the mount point and the folders above
/// it are above them.
fn data_volume_names(path: &Path) -> Vec<PathBuf> {
    FIRMLINKS
        .iter()
        .filter_map(|(link, on_data_volume)| path.strip_prefix(link).ok().map(|rest| on_data_volume.join(rest)))
        .collect()
}

/// `/usr/share/firmlinks`: each line a firmlink's path, a tab, and its
/// folder's path relative to the data volume's root, which is where the
/// volume holding the firmlink's folder is mounted.
static FIRMLINKS: LazyLock<Vec<(PathBuf, PathBuf)>> = LazyLock::new(|| {
    let text = std::fs::read_to_string("/usr/share/firmlinks").unwrap_or_default();
    text.lines()
        .filter_map(|line| {
            // Two fields, as `Firmlinks` in `MeerkatKit` reads them.
            let fields: Vec<&str> = line.split('\t').filter(|field| !field.is_empty()).collect();
            let [link, relative] = fields[..] else { return None };
            let (link, relative) = (Path::new(link), Path::new(relative));
            if !link.is_absolute() || !relative.is_relative() {
                return None;
            }
            let volume = rustix::fs::statfs(link).ok()?;
            let mount: Vec<u8> =
                volume.f_mntonname.iter().map(|&byte| byte.to_ne_bytes()[0]).take_while(|&byte| byte != 0).collect();
            let mount = PathBuf::from(OsString::from_vec(mount));
            (mount.is_absolute() && mount != Path::new("/")).then(|| (link.to_owned(), mount.join(relative)))
        })
        .collect()
});

/// `path` compared without case, as the default (case-insensitive) APFS
/// compares names, so a part that does not exist yet cannot differ from a
/// protected path only in case. macOS paths are UTF-8.
fn folded(path: &Path) -> PathBuf {
    PathBuf::from(path.to_string_lossy().to_lowercase())
}

/// Where the entry leads when followed, even through a symlink whose target
/// does not exist yet (which a following create would make).
fn followed(entry: &Path) -> PathBuf {
    let mut current = entry.to_owned();
    for _ in 0..MAXIMUM_LINKS {
        let Ok(target) = std::fs::read_link(&current) else { return current };
        let base = current.parent().map(Path::to_owned).unwrap_or_default();
        current = self::entry(&base.join(target));
    }
    current
}

/// Each call that reads or changes a path is checked first, then goes to
/// `RealFs`; the rest go to it as they are. `statfs_*` reads only what volume
/// a path is on. Every method `RealFs` implements is listed but
/// `write_file_*` and `read_file_*`, whose defaults open through `open_*`
/// here.
impl FileSystem for GuardedFs {
    fn cwd(&self) -> FsResult<PathBuf> {
        REAL.cwd()
    }

    fn tmp_dir(&self) -> FsResult<PathBuf> {
        REAL.tmp_dir()
    }

    fn chdir(&self, path: &CheckedPath) -> FsResult<()> {
        REAL.chdir(path)
    }

    fn umask(&self, mask: Option<u32>) -> FsResult<u32> {
        REAL.umask(mask)
    }

    /// Every open is a read, checked against what may not be read; one that
    /// may change the file is checked against what may not change too.
    fn open_sync(&self, path: &CheckedPath, options: OpenOptions) -> FsResult<Rc<dyn File>> {
        let changes = writes(options);
        let checks = opening(path, changes);
        let opened = self.checked(Hold::Shared, &checks, || open_std(path, options))?;
        let file = Rc::new(StdFileResourceInner::file(opened, Some(path.to_path_buf())));
        Ok(Rc::new(GuardedFile { file, changes }))
    }

    fn open_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        options: OpenOptions,
    ) -> LocalBoxFuture<'b, FsResult<Rc<dyn File>>>
    where
        'a: 'b,
        Self: 'b,
    {
        let changes = writes(options);
        let named = path.to_path_buf();
        let checks = opening(&named, changes).iter().map(|(path, access)| (path.to_path_buf(), *access)).collect();
        let opened = self.checked_async(Hold::Shared, checks, move || open_std(&path.as_checked_path(), options));
        Box::pin(async move {
            let file = Rc::new(StdFileResourceInner::file(opened.await?, Some(named)));
            Ok(Rc::new(GuardedFile { file, changes }) as Rc<dyn File>)
        })
    }

    fn mkdir_sync(&self, path: &CheckedPath, recursive: bool, mode: Option<u32>) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || REAL.mkdir_sync(path, recursive, mode))
    }

    fn mkdir_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        recursive: bool,
        mode: Option<u32>,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || REAL.mkdir_sync(&path.as_checked_path(), recursive, mode))
    }

    fn chmod_sync(&self, path: &CheckedPath, mode: u32) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Contents)], || REAL.chmod_sync(path, mode))
    }

    fn chmod_async<'a, 'b>(&'a self, path: CheckedPathBuf, mode: u32) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Contents)];
        self.checked_async(Hold::Shared, checks, move || REAL.chmod_sync(&path.as_checked_path(), mode))
    }

    fn chown_sync(&self, path: &CheckedPath, uid: Option<u32>, gid: Option<u32>) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Contents)], || REAL.chown_sync(path, uid, gid))
    }

    fn chown_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        uid: Option<u32>,
        gid: Option<u32>,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Contents)];
        self.checked_async(Hold::Shared, checks, move || REAL.chown_sync(&path.as_checked_path(), uid, gid))
    }

    fn lchmod_sync(&self, path: &CheckedPath, mode: u32) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || REAL.lchmod_sync(path, mode))
    }

    fn lchmod_async<'a, 'b>(&'a self, path: CheckedPathBuf, mode: u32) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || REAL.lchmod_sync(&path.as_checked_path(), mode))
    }

    fn lchown_sync(&self, path: &CheckedPath, uid: Option<u32>, gid: Option<u32>) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || REAL.lchown_sync(path, uid, gid))
    }

    fn lchown_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        uid: Option<u32>,
        gid: Option<u32>,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || REAL.lchown_sync(&path.as_checked_path(), uid, gid))
    }

    fn remove_sync(&self, path: &CheckedPath, recursive: bool) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || REAL.remove_sync(path, recursive))
    }

    fn remove_async<'a, 'b>(&'a self, path: CheckedPathBuf, recursive: bool) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || REAL.remove_sync(&path.as_checked_path(), recursive))
    }

    fn copy_file_sync(&self, oldpath: &CheckedPath, newpath: &CheckedPath) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**oldpath, Access::Read), (&**newpath, Access::Contents)], || {
            regular(oldpath)?;
            REAL.copy_file_sync(oldpath, newpath)
        })
    }

    fn copy_file_async<'a, 'b>(
        &'a self,
        oldpath: CheckedPathBuf,
        newpath: CheckedPathBuf,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(oldpath.to_path_buf(), Access::Read), (newpath.to_path_buf(), Access::Contents)];
        self.checked_async(Hold::Shared, checks, move || {
            regular(&oldpath.as_checked_path())?;
            REAL.copy_file_sync(&oldpath.as_checked_path(), &newpath.as_checked_path())
        })
    }

    /// `RealFs` copies a whole tree here with `std`, below the one path a
    /// check would see, and copies symlinks by making them. No op of this
    /// Deno calls it (`node:fs`'s `cp` has ops of its own, which are off),
    /// so it is refused rather than checked.
    fn cp_sync(&self, path: &CheckedPath, _new_path: &CheckedPath) -> FsResult<()> {
        Err(refused(path, "is not copied: copying a folder is not available to rules"))
    }

    fn cp_async<'a, 'b>(&'a self, path: CheckedPathBuf, new_path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        Box::pin(future::ready(self.cp_sync(&path.as_checked_path(), &new_path.as_checked_path())))
    }

    fn stat_sync(&self, path: &CheckedPath) -> FsResult<FsStat> {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || REAL.stat_sync(path))
    }

    fn stat_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<FsStat>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        self.checked_async(Hold::Shared, checks, move || REAL.stat_sync(&path.as_checked_path()))
    }

    fn lstat_sync(&self, path: &CheckedPath) -> FsResult<FsStat> {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || REAL.lstat_sync(path))
    }

    fn lstat_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<FsStat>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        self.checked_async(Hold::Shared, checks, move || REAL.lstat_sync(&path.as_checked_path()))
    }

    fn statfs_sync(&self, path: &CheckedPath, bigint: bool) -> FsResult<FsStatFs> {
        REAL.statfs_sync(path, bigint)
    }

    fn statfs_async<'a, 'b>(&'a self, path: CheckedPathBuf, bigint: bool) -> LocalBoxFuture<'b, FsResult<FsStatFs>>
    where
        'a: 'b,
        Self: 'b,
    {
        REAL.statfs_async(path, bigint)
    }

    fn realpath_sync(&self, path: &CheckedPath) -> FsResult<PathBuf> {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || REAL.realpath_sync(path))
    }

    fn realpath_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<PathBuf>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        self.checked_async(Hold::Shared, checks, move || REAL.realpath_sync(&path.as_checked_path()))
    }

    fn read_dir_sync(&self, path: &CheckedPath) -> FsResult<Vec<FsDirEntry>> {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || REAL.read_dir_sync(path))
    }

    fn read_dir_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<FsReadDirRc>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        let listed = self.checked_async(Hold::Shared, checks, move || REAL.read_dir_sync(&path.as_checked_path()));
        Box::pin(async move { Ok(new_rc(Listed(Mutex::new(listed.await?.into_iter()))) as FsReadDirRc) })
    }

    fn rename_sync(&self, oldpath: &CheckedPath, newpath: &CheckedPath) -> FsResult<()> {
        let checks = [(&**oldpath, Access::Entry), (&**newpath, Access::Entry)];
        self.checked(Hold::Renaming, &checks, || REAL.rename_sync(oldpath, newpath))
    }

    fn rename_async<'a, 'b>(
        &'a self,
        oldpath: CheckedPathBuf,
        newpath: CheckedPathBuf,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(oldpath.to_path_buf(), Access::Entry), (newpath.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Renaming, checks, move || {
            REAL.rename_sync(&oldpath.as_checked_path(), &newpath.as_checked_path())
        })
    }

    fn rmdir_sync(&self, path: &CheckedPath) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || REAL.rmdir_sync(path))
    }

    fn rmdir_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || REAL.rmdir_sync(&path.as_checked_path()))
    }

    /// A hard link to a protected file would be a second, unprotected name
    /// for it: `oldpath` is checked as well.
    fn link_sync(&self, oldpath: &CheckedPath, newpath: &CheckedPath) -> FsResult<()> {
        let checks = [(&**oldpath, Access::Contents), (&**newpath, Access::Entry)];
        self.checked(Hold::Shared, &checks, || REAL.link_sync(oldpath, newpath))
    }

    fn link_async<'a, 'b>(
        &'a self,
        oldpath: CheckedPathBuf,
        newpath: CheckedPathBuf,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(oldpath.to_path_buf(), Access::Contents), (newpath.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || {
            REAL.link_sync(&oldpath.as_checked_path(), &newpath.as_checked_path())
        })
    }

    fn symlink_sync(
        &self,
        oldpath: &CheckedPath,
        newpath: &CheckedPath,
        file_type: Option<FsFileType>,
    ) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**newpath, Access::Entry)], || REAL.symlink_sync(oldpath, newpath, file_type))
    }

    fn symlink_async<'a, 'b>(
        &'a self,
        oldpath: CheckedPathBuf,
        newpath: CheckedPathBuf,
        file_type: Option<FsFileType>,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(newpath.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || {
            REAL.symlink_sync(&oldpath.as_checked_path(), &newpath.as_checked_path(), file_type)
        })
    }

    fn read_link_sync(&self, path: &CheckedPath) -> FsResult<PathBuf> {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || REAL.read_link_sync(path))
    }

    fn read_link_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<PathBuf>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        self.checked_async(Hold::Shared, checks, move || REAL.read_link_sync(&path.as_checked_path()))
    }

    fn truncate_sync(&self, path: &CheckedPath, len: u64) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Contents)], || REAL.truncate_sync(path, len))
    }

    fn truncate_async<'a, 'b>(&'a self, path: CheckedPathBuf, len: u64) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Contents)];
        self.checked_async(Hold::Shared, checks, move || REAL.truncate_sync(&path.as_checked_path(), len))
    }

    fn utime_sync(
        &self,
        path: &CheckedPath,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Contents)], || {
            REAL.utime_sync(path, atime_secs, atime_nanos, mtime_secs, mtime_nanos)
        })
    }

    fn utime_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Contents)];
        self.checked_async(Hold::Shared, checks, move || {
            REAL.utime_sync(&path.as_checked_path(), atime_secs, atime_nanos, mtime_secs, mtime_nanos)
        })
    }

    fn lutime_sync(
        &self,
        path: &CheckedPath,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> FsResult<()> {
        self.checked(Hold::Shared, &[(&**path, Access::Entry)], || {
            REAL.lutime_sync(path, atime_secs, atime_nanos, mtime_secs, mtime_nanos)
        })
    }

    fn lutime_async<'a, 'b>(
        &'a self,
        path: CheckedPathBuf,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> LocalBoxFuture<'b, FsResult<()>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Entry)];
        self.checked_async(Hold::Shared, checks, move || {
            REAL.lutime_sync(&path.as_checked_path(), atime_secs, atime_nanos, mtime_secs, mtime_nanos)
        })
    }

    /// A path that may not be read does not exist, as far as rule code can
    /// tell: `exists` has no error to give.
    fn exists_sync(&self, path: &CheckedPath) -> bool {
        self.checked(Hold::Shared, &[(&**path, Access::Read)], || Ok(REAL.exists_sync(path))).unwrap_or(false)
    }

    fn exists_async<'a, 'b>(&'a self, path: CheckedPathBuf) -> LocalBoxFuture<'b, FsResult<bool>>
    where
        'a: 'b,
        Self: 'b,
    {
        let checks = vec![(path.to_path_buf(), Access::Read)];
        let exists = self.checked_async(Hold::Shared, checks, move || Ok(REAL.exists_sync(&path.as_checked_path())));
        Box::pin(async move { Ok(exists.await.unwrap_or(false)) })
    }
}

/// A file a rule's code opened. Deno's and Node's descriptor calls change
/// its mode, owner and times with no check of their own, and the system
/// lets a read-only descriptor's owner do all three, so a file opened only
/// to read refuses them; a writing open passed the checks above. Everything
/// else goes to the file as it is.
struct GuardedFile {
    file: Rc<dyn File>,
    changes: bool,
}

impl GuardedFile {
    fn may_change(&self, what: &str) -> FsResult<()> {
        if self.changes {
            return Ok(());
        }
        let name = self.file.maybe_path().map_or_else(|| "a file".to_owned(), |path| path.display().to_string());
        Err(FsError::Io(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{name} was opened only to read, so its {what} cannot change through it"),
        )))
    }

    fn refused<'b, T: 'b>(&self, what: &str) -> Option<LocalBoxFuture<'b, FsResult<T>>> {
        self.may_change(what).err().map(|error| Box::pin(future::ready(Err(error))) as LocalBoxFuture<'b, FsResult<T>>)
    }
}

impl File for GuardedFile {
    fn maybe_path(&self) -> Option<&Path> {
        self.file.maybe_path()
    }

    fn read_sync(self: Rc<Self>, buf: &mut [u8]) -> FsResult<usize> {
        self.file.clone().read_sync(buf)
    }

    fn read<'t>(self: Rc<Self>, limit: usize) -> LocalBoxFuture<'t, FsResult<BufView>>
    where
        Self: 't,
    {
        self.file.clone().read(limit)
    }

    fn read_byob<'t>(self: Rc<Self>, buf: BufMutView) -> LocalBoxFuture<'t, FsResult<(usize, BufMutView)>>
    where
        Self: 't,
    {
        self.file.clone().read_byob(buf)
    }

    fn write_sync(self: Rc<Self>, buf: &[u8]) -> FsResult<usize> {
        self.file.clone().write_sync(buf)
    }

    fn write<'t>(self: Rc<Self>, buf: BufView) -> LocalBoxFuture<'t, FsResult<WriteOutcome>>
    where
        Self: 't,
    {
        self.file.clone().write(buf)
    }

    fn write_all_sync(self: Rc<Self>, buf: &[u8]) -> FsResult<()> {
        self.file.clone().write_all_sync(buf)
    }

    fn write_all<'t>(self: Rc<Self>, buf: BufView) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().write_all(buf)
    }

    fn read_all_sync(self: Rc<Self>) -> FsResult<Cow<'static, [u8]>> {
        self.file.clone().read_all_sync()
    }

    fn read_all_async<'t>(self: Rc<Self>) -> LocalBoxFuture<'t, FsResult<Cow<'static, [u8]>>>
    where
        Self: 't,
    {
        self.file.clone().read_all_async()
    }

    fn chmod_sync(self: Rc<Self>, mode: u32) -> FsResult<()> {
        self.may_change("mode")?;
        self.file.clone().chmod_sync(mode)
    }

    fn chmod_async<'t>(self: Rc<Self>, mode: u32) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.refused("mode").unwrap_or_else(|| self.file.clone().chmod_async(mode))
    }

    fn chown_sync(self: Rc<Self>, uid: Option<u32>, gid: Option<u32>) -> FsResult<()> {
        self.may_change("owner")?;
        self.file.clone().chown_sync(uid, gid)
    }

    fn chown_async<'t>(self: Rc<Self>, uid: Option<u32>, gid: Option<u32>) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.refused("owner").unwrap_or_else(|| self.file.clone().chown_async(uid, gid))
    }

    fn seek_sync(self: Rc<Self>, pos: io::SeekFrom) -> FsResult<u64> {
        self.file.clone().seek_sync(pos)
    }

    fn seek_async<'t>(self: Rc<Self>, pos: io::SeekFrom) -> LocalBoxFuture<'t, FsResult<u64>>
    where
        Self: 't,
    {
        self.file.clone().seek_async(pos)
    }

    fn datasync_sync(self: Rc<Self>) -> FsResult<()> {
        self.file.clone().datasync_sync()
    }

    fn datasync_async<'t>(self: Rc<Self>) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().datasync_async()
    }

    fn sync_sync(self: Rc<Self>) -> FsResult<()> {
        self.file.clone().sync_sync()
    }

    fn sync_async<'t>(self: Rc<Self>) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().sync_async()
    }

    fn stat_sync(self: Rc<Self>) -> FsResult<FsStat> {
        self.file.clone().stat_sync()
    }

    fn stat_async<'t>(self: Rc<Self>) -> LocalBoxFuture<'t, FsResult<FsStat>>
    where
        Self: 't,
    {
        self.file.clone().stat_async()
    }

    fn lock_sync(self: Rc<Self>, exclusive: bool) -> FsResult<()> {
        self.file.clone().lock_sync(exclusive)
    }

    fn lock_async<'t>(self: Rc<Self>, exclusive: bool) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().lock_async(exclusive)
    }

    fn try_lock_sync(self: Rc<Self>, exclusive: bool) -> FsResult<bool> {
        self.file.clone().try_lock_sync(exclusive)
    }

    fn try_lock_async<'t>(self: Rc<Self>, exclusive: bool) -> LocalBoxFuture<'t, FsResult<bool>>
    where
        Self: 't,
    {
        self.file.clone().try_lock_async(exclusive)
    }

    fn unlock_sync(self: Rc<Self>) -> FsResult<()> {
        self.file.clone().unlock_sync()
    }

    fn unlock_async<'t>(self: Rc<Self>) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().unlock_async()
    }

    fn truncate_sync(self: Rc<Self>, len: u64) -> FsResult<()> {
        self.file.clone().truncate_sync(len)
    }

    fn truncate_async<'t>(self: Rc<Self>, len: u64) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.file.clone().truncate_async(len)
    }

    fn utime_sync(
        self: Rc<Self>,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> FsResult<()> {
        self.may_change("times")?;
        self.file.clone().utime_sync(atime_secs, atime_nanos, mtime_secs, mtime_nanos)
    }

    fn utime_async<'t>(
        self: Rc<Self>,
        atime_secs: i64,
        atime_nanos: u32,
        mtime_secs: i64,
        mtime_nanos: u32,
    ) -> LocalBoxFuture<'t, FsResult<()>>
    where
        Self: 't,
    {
        self.refused("times")
            .unwrap_or_else(|| self.file.clone().utime_async(atime_secs, atime_nanos, mtime_secs, mtime_nanos))
    }

    fn read_at_sync(self: Rc<Self>, buf: &mut [u8], position: u64) -> FsResult<usize> {
        self.file.clone().read_at_sync(buf, position)
    }

    fn read_at_async<'t>(
        self: Rc<Self>,
        buf: BufMutView,
        position: u64,
    ) -> LocalBoxFuture<'t, FsResult<(usize, BufMutView)>>
    where
        Self: 't,
    {
        self.file.clone().read_at_async(buf, position)
    }

    fn write_at_sync(self: Rc<Self>, buf: &[u8], position: u64) -> FsResult<usize> {
        self.file.clone().write_at_sync(buf, position)
    }

    fn as_stdio(self: Rc<Self>) -> FsResult<Stdio> {
        self.file.clone().as_stdio()
    }

    fn backing_fd(self: Rc<Self>) -> Option<ResourceHandleFd> {
        self.file.clone().backing_fd()
    }

    /// A copy of the descriptor keeps what this one may do.
    fn try_clone_inner(self: Rc<Self>) -> FsResult<Rc<dyn File>> {
        Ok(Rc::new(GuardedFile { file: self.file.clone().try_clone_inner()?, changes: self.changes }))
    }
}

#[cfg(test)]
mod tests {
    use super::{Access, Protected, data_volume_names, entry, folded, resolve};
    use serde_json::Value;
    use std::path::{Path, PathBuf};

    /// The data volume's name for a folder, which `realpath` keeps.
    fn on_data_volume(path: &Path) -> PathBuf {
        Path::new("/System/Volumes/Data").join(path.strip_prefix("/").unwrap())
    }

    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("meerkat-protected-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(directory.join("Folder")).unwrap();
        directory.canonicalize().unwrap()
    }

    /// One folder, one name: its firmlinked and data-volume names, its
    /// case, and a part that does not exist yet below each.
    #[test]
    fn a_folder_has_one_real_path() {
        let directory = scratch("names");
        let folder = directory.join("Folder");
        assert!(on_data_volume(&folder).exists(), "the scratch folder is on the data volume");
        assert_eq!(resolve(&on_data_volume(&folder)), folder);
        assert_eq!(resolve(&on_data_volume(&folder).join("new/file")), folder.join("new/file"));
        assert_eq!(entry(&directory.join("FOLDER")), folder);
        assert_eq!(entry(&on_data_volume(&directory).join("FOLDER")), folder);
        assert!(data_volume_names(&folder).contains(&on_data_volume(&folder)));
        std::fs::remove_dir_all(&directory).unwrap();
    }

    /// The data volume's mount point, and the folders above it, are above
    /// every protected path on the volume, though no real path is under it.
    /// Only checked, nothing is changed.
    #[test]
    fn the_data_volume_is_above_its_folders() {
        let directory = scratch("above");
        let protected = Protected::default();
        protected.set(&[directory.join("Folder").display().to_string()], &[]);
        for above in ["/System/Volumes/Data", "/System/Volumes", "/System"] {
            assert!(protected.check(Path::new(above), Access::Entry).is_err(), "{above}");
        }
        assert!(protected.check(&on_data_volume(&directory.join("FOLDER/x")), Access::Contents).is_err());
        assert!(protected.check(&directory.join("other"), Access::Entry).is_ok());
        std::fs::remove_dir_all(&directory).unwrap();
    }

    /// The cases the daemon's `CapabilityGrants.protectedPath` is held to as
    /// well (`ProtectedPathCases` in `MeerkatDaemonTests`), so the two
    /// implementations of what a protected path covers cannot drift apart.
    #[test]
    fn protected_paths_cover_the_shared_cases() {
        let spec: Value = serde_json::from_str(include_str!("protected_cases.json")).unwrap();
        let root = scratch("cases");
        let at = |path: &str| -> PathBuf {
            if let Some(rest) = path.strip_prefix("@data/") {
                on_data_volume(&root.join(rest))
            } else {
                root.join(path)
            }
        };
        let strings = |value: &Value| -> Vec<String> {
            value.as_array().unwrap().iter().map(|item| item.as_str().unwrap().to_owned()).collect()
        };
        let layout = &spec["layout"];
        for folder in strings(&layout["folders"]) {
            std::fs::create_dir_all(at(&folder)).unwrap();
        }
        for file in strings(&layout["files"]) {
            std::fs::write(at(&file), "").unwrap();
        }
        for link in layout["links"].as_array().unwrap() {
            let (link, to) = (link["at"].as_str().unwrap(), link["to"].as_str().unwrap());
            std::os::unix::fs::symlink(at(to), at(link)).unwrap();
        }
        let protected = Protected::default();
        let named: Vec<String> =
            strings(&spec["protected"]).iter().map(|path| at(path).display().to_string()).collect();
        protected.set(&named, &[]);
        let mut wrong = Vec::new();
        for case in spec["cases"].as_array().unwrap() {
            let path = case["path"].as_str().unwrap();
            let touches = protected.changes_protected(&[&folded(&entry(&at(path)))]);
            if touches != case["touches"].as_bool().unwrap() {
                wrong.push(format!("{path} ({}): touches is {touches}", case["why"].as_str().unwrap()));
            }
        }
        std::fs::remove_dir_all(&root).unwrap();
        assert!(wrong.is_empty(), "{wrong:#?}");
    }
}
