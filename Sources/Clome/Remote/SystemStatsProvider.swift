// SystemStatsProvider.swift
// Clome — Collects system stats (CPU, memory, disk) for the Multi-Mac Dashboard.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class SystemStatsProvider {

    func collectStats() -> SystemStats {
        let cpu = cpuUsage()
        let (memUsed, memTotal) = memoryUsage()
        let (diskUsed, diskTotal) = diskUsage()
        let processes = topProcesses()
        let uptime = ProcessInfo.processInfo.systemUptime

        return SystemStats(
            cpuUsagePercent: cpu,
            memoryUsedGB: memUsed,
            memoryTotalGB: memTotal,
            diskUsedGB: diskUsed,
            diskTotalGB: diskTotal,
            activeProcesses: processes,
            uptimeSeconds: uptime
        )
    }

    // MARK: - CPU

    private func cpuUsage() -> Double {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }

        let user = Double(loadInfo.cpu_ticks.0)   // CPU_STATE_USER
        let system = Double(loadInfo.cpu_ticks.1)  // CPU_STATE_SYSTEM
        let idle = Double(loadInfo.cpu_ticks.2)    // CPU_STATE_IDLE
        let nice = Double(loadInfo.cpu_ticks.3)    // CPU_STATE_NICE

        let total = user + system + idle + nice
        guard total > 0 else { return 0.0 }
        return ((user + system + nice) / total) * 100.0
    }

    // MARK: - Memory

    private func memoryUsage() -> (usedGB: Double, totalGB: Double) {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / (1024 * 1024 * 1024)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, totalGB) }

        // Use sysconf to get page size in a concurrency-safe way (vm_kernel_page_size is a global var)
        let pageSize = Double(sysconf(Int32(_SC_PAGESIZE)))
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let usedGB = (active + wired + compressed) / (1024 * 1024 * 1024)

        return (usedGB, totalGB)
    }

    // MARK: - Disk

    private func diskUsage() -> (usedGB: Double, totalGB: Double) {
        var stat = statvfs()
        guard statvfs("/", &stat) == 0 else { return (0, 0) }

        let blockSize = Double(stat.f_frsize)
        let totalGB = (Double(stat.f_blocks) * blockSize) / (1024 * 1024 * 1024)
        let freeGB = (Double(stat.f_bavail) * blockSize) / (1024 * 1024 * 1024)

        return (totalGB - freeGB, totalGB)
    }

    // MARK: - Top Processes

    private func topProcesses() -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pcpu,comm", "--sort=-pcpu"]
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output.components(separatedBy: "\n")
                .dropFirst() // header
                .prefix(5)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    // Extract just the process name (last path component)
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    let name = String(parts[1])
                    return (name as NSString).lastPathComponent
                }
        } catch {
            return []
        }
    }
}
