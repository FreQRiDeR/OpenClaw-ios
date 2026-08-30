#!/usr/bin/env python3
"""
Dashboard: system stats card
Returns JSON: cpu_percent, ram_used_mb, ram_total_mb, ram_percent, uptime_seconds, load_avg
Works on macOS and Linux. Uses psutil when available (both), else falls back to
platform-specific readers on Linux.
"""
import json, time, os

try:
    import psutil
    def get_uptime():
        try:
            return round(time.time() - psutil.boot_time())
        except Exception:
            try:
                with open('/proc/uptime') as f:
                    return float(f.read().split()[0])
            except Exception:
                return None

    def get_mem():
        try:
            vm = psutil.virtual_memory()
            total_mb = round(vm.total / 1024 / 1024)
            used_mb = round(vm.used / 1024 / 1024)
            return {
                'ram_total_mb': total_mb,
                'ram_used_mb': used_mb,
                'ram_available_mb': round(vm.available / 1024 / 1024),
                'ram_percent': round(vm.percent, 1),
            }
        except Exception:
            return {}

    def get_cpu():
        try:
            return {'cpu_percent': round(psutil.cpu_percent(interval=0.5), 1)}
        except Exception:
            # Never hard-crash on macOS: guard the Linux /proc/stat fallback.
            try:
                if not os.path.exists('/proc/stat'):
                    return {}
                def read_stat():
                    with open('/proc/stat') as f:
                        line = f.readline().split()
                    user, nice, system, idle, iowait = int(line[1]), int(line[2]), int(line[3]), int(line[4]), int(line[5])
                    total = user + nice + system + idle + iowait
                    return idle + iowait, total
                idle1, total1 = read_stat()
                time.sleep(0.5)
                idle2, total2 = read_stat()
                delta_idle = idle2 - idle1
                delta_total = total2 - total1
                cpu = round((1 - delta_idle / delta_total) * 100, 1) if delta_total > 0 else 0
                return {'cpu_percent': cpu}
            except Exception:
                return {}

    def get_load():
        try:
            load = os.getloadavg()
            return {'load_avg_1m': round(load[0], 2), 'load_avg_5m': round(load[1], 2)}
        except Exception:
            return {}

    def get_disk():
        # Use the user's home dir (works on macOS + Linux).
        disk_path = os.path.expanduser('~')
        try:
            du = psutil.disk_usage(disk_path)
            total_mb = round(du.total / 1024 / 1024)
            used_mb = round(du.used / 1024 / 1024)
            return {
                'disk_total_mb': total_mb,
                'disk_used_mb': used_mb,
                'disk_free_mb': round(du.free / 1024 / 1024),
                'disk_percent': round(du.percent, 1),
            }
        except Exception:
            return {}

except ImportError:
    # Linux-only fallback readers (/proc-based)
    def get_uptime():
        try:
            with open('/proc/uptime') as f:
                return float(f.read().split()[0])
        except Exception:
            return None
    def get_mem():
        try:
            mem = {}
            with open('/proc/meminfo') as f:
                for line in f:
                    parts = line.split()
                    if parts[0] in ('MemTotal:', 'MemAvailable:'):
                        mem[parts[0].rstrip(':')] = int(parts[1])
            total_mb = mem['MemTotal'] / 1024
            avail_mb = mem['MemAvailable'] / 1024
            used_mb = total_mb - avail_mb
            return {
                'ram_total_mb': round(total_mb),
                'ram_used_mb': round(used_mb),
                'ram_available_mb': round(avail_mb),
                'ram_percent': round(used_mb / total_mb * 100, 1),
            }
        except Exception:
            return {}

    def get_cpu():
        # Linux: /proc/stat based reader
        if os.path.exists('/proc/stat'):
            def read_stat():
                with open('/proc/stat') as f:
                    line = f.readline().split()
                user, nice, system, idle, iowait = int(line[1]), int(line[2]), int(line[3]), int(line[4]), int(line[5])
                total = user + nice + system + idle + iowait
                return idle + iowait, total
            idle1, total1 = read_stat()
            time.sleep(0.5)
            idle2, total2 = read_stat()
            delta_idle = idle2 - idle1
            delta_total = total2 - total1
            cpu = round((1 - delta_idle / delta_total) * 100, 1) if delta_total > 0 else 0
            return {'cpu_percent': cpu}
        # macOS / BSD: sysctl hw.ncpu + loadavg estimate (matches Activity Monitor's 1-min load)
        try:
            import subprocess
            nproc = int(subprocess.check_output(['sysctl', '-n', 'hw.ncpu']).decode().strip() or '1')
            load = os.getloadavg()[0]
            cpu = min(100.0, round(load / nproc * 100, 1))
            return {'cpu_percent': cpu}
        except Exception:
            return {}

    def get_load():
        try:
            load = os.getloadavg()
            return {'load_avg_1m': round(load[0], 2), 'load_avg_5m': round(load[1], 2)}
        except Exception:
            return {}

    def get_disk():
        if not os.path.exists('/proc'):
            return {}  # macOS fallback handled by psutil path; nothing worse than empty here
        try:
            st = os.statvfs(os.path.expanduser('~'))
            total_mb = round(st.f_blocks * st.f_frsize / 1024 / 1024)
            free_mb = round(st.f_bavail * st.f_frsize / 1024 / 1024)
            used_mb = total_mb - free_mb
            return {
                'disk_total_mb': total_mb,
                'disk_used_mb': used_mb,
                'disk_free_mb': free_mb,
                'disk_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0,
            }
        except Exception:
            return {}

result = {
    'timestamp': int(time.time()),
    'uptime_seconds': get_uptime(),
}
result.update(get_cpu())
result.update(get_mem())
result.update(get_load())
result.update(get_disk())

print(json.dumps(result))
