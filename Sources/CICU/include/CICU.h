// ICU's C regex API from the macOS SDK (libicucore). Used for `match`
// regexes because, unlike NSRegularExpression, it can bound a match's
// running time (uregex_setTimeLimit): ICU backtracks, and a rule's pattern
// runs in the daemon on every event.
//
// Apple ships libicucore without versioned symbol names.
#define U_DISABLE_RENAMING 1
#include <unicode/uregex.h>
