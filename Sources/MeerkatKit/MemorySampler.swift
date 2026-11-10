import Darwin
import Foundation

/// System-wide memory via `host_statistics64` (the same source `vm_stat` uses).
public enum MemorySampler {
    private static let hostVMInfo64: Int32 = 4  // HOST_VM_INFO64

    public static func sample() throws -> MemorySample {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), hostVMInfo64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw MeerkatError.hostStatisticsFailed(kr) }

        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        guard pageResult == KERN_SUCCESS, pageSize > 0 else { throw MeerkatError.hostStatisticsFailed(pageResult) }
        let page = UInt64(pageSize)

        func mb(_ pages: UInt32) -> Double {
            Double(UInt64(pages) * page) / 1_000_000.0
        }

        let swap = try swapUsage()

        return MemorySample(
            pageSize: page,
            freeMB: mb(vm.free_count),
            activeMB: mb(vm.active_count),
            inactiveMB: mb(vm.inactive_count),
            wiredMB: mb(vm.wire_count),
            compressedMB: mb(vm.compressor_page_count),
            swapUsedMB: swap.used,
            swapTotalMB: swap.total
        )
    }

    /// Throws rather than report no swap, which is a real and common value.
    private static func swapUsage() throws -> (used: Double, total: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let rc = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard rc == 0 else { throw MeerkatError.swapUnavailable }
        let toMB = { (bytes: UInt64) in Double(bytes) / 1_000_000.0 }
        return (toMB(usage.xsu_used), toMB(usage.xsu_total))
    }
}
