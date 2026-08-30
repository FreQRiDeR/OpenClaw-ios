#!/usr/bin/env python3
"""
Dashboard: system stats card (macOS + Linux)
Returns JSON: cpu_percent, ram_used_mb, ram_total_mb, ram_percent,
              disk_used_mb, disk_total_mb, disk_percent,
              load_avg_1m, load_avg_5m, uptime_seconds, timestamp
"""
import json, time, subprocess, os, sys

IS_MAC = sys.platform == 'darwin'

def get_uptime():
    try:
        if IS_MAC:
            out = subprocess.run(['sysctl', '-n', 'kern.boottime'], capture_output=True, text=True, timeout=5).stdout
            # e.g. { sec = 1712345678, usec = 123456 } Sun Jan  1 00:00:00 2024
            import re
            m = re.search(r'sec\s*=\s*(\d+)', out)
            if m:
                return max(0, time.time() - int(m.group(1)))
            return None
        with open('/proc/uptime') as f:
            return float(f.read().split()[0])
    except Exception:
        return None

def get_mem():
    try:
        if IS_MAC:
            out = subprocess.run(['vm_stat'], capture_output=True, text=True, timeout=5).stdout
            page_size = 4096
            for line in out.splitlines():
                if line.startswith('Mach Virtual Memory Statistics'):
                    continue
                if 'page size of' in line:
                    page_size = int(line.split('page size of')[-1].strip().rstrip('.'))
                    break
            stats = {}
            for line in out.splitlines():
                # Skip the header line: "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
                if line.startswith('Mach Virtual Memory Statistics'):
                    continue
                if ':' in line:
                    k, v = line.split(':', 1)
                    try:
                        stats[k.strip()] = int(v.strip().rstrip('.'))
                    except ValueError:
                        continue
            pages_free = stats.get('Pages free', 0)
            pages_inactive = stats.get('Pages inactive', 0)
            pages_speculative = stats.get('Pages speculative', 0)
            pages_purgeable = stats.get('Pages purgeable', 0)
            pages_wired = stats.get('Pages wired down', 0)
            pages_compressed = stats.get('Pages occupied by compressor', 0)
            avail_pages = pages_free + pages_inactive + pages_speculative + pages_purgeable
            used_pages = pages_wired + pages_compressed
            total_pages = avail_pages + used_pages
            total_mb = round(total_pages * page_size / 1024 / 1024)
            used_mb = round(used_pages * page_size / 1024 / 1024)
            avail_mb = total_mb - used_mb
            return {
                'ram_total_mb': total_mb,
                'ram_used_mb': used_mb,
                'ram_available_mb': avail_mb,
                'ram_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0
            }
        mem = {}
        with open('/proc/meminfo') as f:
            for line in f:
                parts = line.split()
                if parts[0] in ('MemTotal:', 'MemAvailable:'):
                    mem[parts[0].rstrip(':')] = int(parts[1])  # kB
        total_mb = mem['MemTotal'] / 1024
        avail_mb = mem['MemAvailable'] / 1024
        used_mb = total_mb - avail_mb
        return {
            'ram_total_mb': round(total_mb),
            'ram_used_mb': round(used_mb),
            'ram_available_mb': round(avail_mb),
            'ram_percent': round(used_mb / total_mb * 100, 1)
        }
    except Exception:
        return {}

def get_cpu():
    try:
        if IS_MAC:
            # Sample host CPU usage via top -l 2 (second sample is the delta)
            out = subprocess.run(
                ['top', '-l', '2', '-n', '0', '-s', '1'],
                capture_output=True, text=True, timeout=10
            ).stdout
            cpu_line = None
            for line in out.splitlines():
                if 'CPU usage:' in line:
                    cpu_line = line
            if cpu_line:
                import re
                idle = 0.0
                m = re.search(r'(\d+\.\d+)% idle', cpu_line)
                if m:
                    idle = float(m.group(1))
                return {'cpu_percent': round(100 - idle, 1)}
            return {'cpu_percent': 0.0}
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
        return {'cpu_percent': 0.0}

def get_load():
    try:
        load = os.getloadavg()
        return {'load_avg_1m': round(load[0], 2), 'load_avg_5m': round(load[1], 2)}
    except Exception:
        return {}

def get_disk():
    try:
        if IS_MAC:
            st = os.statvfs(os.path.expanduser('~'))
        else:
            st = os.statvfs('/home/node')
        total_mb = round(st.f_blocks * st.f_frsize / 1024 / 1024)
        free_mb = round(st.f_bavail * st.f_frsize / 1024 / 1024)
        used_mb = total_mb - free_mb
        return {
            'disk_total_mb': total_mb,
            'disk_used_mb': used_mb,
            'disk_free_mb': free_mb,
            'disk_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0
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
