import Foundation
import Combine
import Darwin

final class SystemStatsService: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsed: UInt64 = 0
    let memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory

    private var previousCpuNanos: UInt64?
    private var previousWallNanos: UInt64?
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        previousCpuNanos = processCPUNanos()
        previousWallNanos = wallNanos()
        memoryUsed = processMemory()

        cancellable = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func refresh() {
        memoryUsed = processMemory()
        cpuUsage = processCPUPercent()
    }

    private func processMemory() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private func processCPUNanos() -> UInt64 {
        var usage = rusage()
        let ret = withUnsafeMutablePointer(to: &usage) { getrusage(RUSAGE_SELF, $0) }
        guard ret == 0 else { return 0 }
        let userNanos = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1000
        let sysNanos = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1000
        return userNanos + sysNanos
    }

    private func wallNanos() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = mach_absolute_time()
        return now * UInt64(info.numer) / UInt64(info.denom)
    }

    private func processCPUPercent() -> Double {
        guard let prevCpu = previousCpuNanos else { return 0 }
        let currentCpu = processCPUNanos()
        let currentWall = wallNanos()

        guard let prevWall = previousWallNanos else { return 0 }

        previousCpuNanos = currentCpu
        previousWallNanos = currentWall

        let cpuDelta = currentCpu > prevCpu ? currentCpu - prevCpu : 0
        let wallDelta = currentWall > prevWall ? currentWall - prevWall : 1

        return wallDelta > 0 ? Double(cpuDelta) / Double(wallDelta) * 100 : 0
    }

    var memoryUsedFormatted: String {
        byteCount(memoryUsed)
    }

    var memoryTotalFormatted: String {
        byteCount(memoryTotal)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
