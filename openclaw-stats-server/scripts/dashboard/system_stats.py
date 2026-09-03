#!/usr/bin/env python3
"""
Dashboard: system stats card (macOS + Linux + Windows)
Returns JSON: cpu_percent, ram_used_mb, ram_total_mb, ram_percent,
              disk_used_mb, disk_total_mb, disk_percent,
              load_avg_1m, load_avg_5m, uptime_seconds, timestamp

Every key is ALWAYS present with a numeric value — the iOS SystemStatsDTO has
non-optional fields, so a missing key breaks the whole card. Windows has no
load average; we emit 0.0 there. Zero third-party deps (ctypes on Windows).
"""
import json, time, subprocess, os, sys, shutil
IS_MAC = sys.platform == 'darwin'
IS_WIN = sys.platform.startswith('win')


def _win_uptime():
    import ctypes
    ctypes.windll.kernel32.GetTickCount64.restype = ctypes.c_ulonglong
    return ctypes.windll.kernel32.GetTickCount64() / 1000.0


def _win_mem():
    import ctypes
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ('dwLength', ctypes.c_ulong), ('dwMemoryLoad', ctypes.c_ulong),
            ('ullTotalPhys', ctypes.c_ulonglong), ('ullAvailPhys', ctypes.c_ulonglong),
            ('ullTotalPageFile', ctypes.c_ulonglong), ('ullAvailPageFile', ctypes.c_ulonglong),
            ('ullTotalVirtual', ctypes.c_ulonglong), ('ullAvailVirtual', ctypes.c_ulonglong),
            ('ullAvailExtendedVirtual', ctypes.c_ulonglong),
        ]
    st = MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
        return {}
    total_mb = round(st.ullTotalPhys / 1024 / 1024)
    avail_mb = round(st.ullAvailPhys / 1024 / 1024)
    used_mb = total_mb - avail_mb
    return {
        'ram_total_mb': total_mb,
        'ram_used_mb': used_mb,
        'ram_available_mb': avail_mb,
        'ram_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0,
    }


def _win_cpu():
    """System-wide CPU % from two GetSystemTimes samples (idle/kernel/user 100ns ticks)."""
    import ctypes
    from ctypes import wintypes
    def sample():
        idle, kern, user = wintypes.FILETIME(), wintypes.FILETIME(), wintypes.FILETIME()
        ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user))
        to_int = lambda ft: (ft.dwHighDateTime << 32) | ft.dwLowDateTime
        i, k, u = to_int(idle), to_int(kern), to_int(user)
        return i, k + u  # kernel time includes idle
    i1, t1 = sample()
    time.sleep(0.5)
    i2, t2 = sample()
    dt = t2 - t1
    return {'cpu_percent': round((1 - (i2 - i1) / dt) * 100, 1) if dt > 0 else 0.0}

def get_uptime():
    try:
        if IS_WIN:
            return _win_uptime()
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
        if IS_WIN:
            return _win_mem()
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
        if IS_WIN:
            return _win_cpu()
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
    # Windows has no load average (os.getloadavg is missing) — emit 0.0 so the DTO decodes.
    try:
        load = os.getloadavg()
        return {'load_avg_1m': round(load[0], 2), 'load_avg_5m': round(load[1], 2)}
    except Exception:
        return {'load_avg_1m': 0.0, 'load_avg_5m': 0.0}
def get_disk():
    # shutil.disk_usage is cross-platform; measure the volume holding the user's home
    # (where ~/.openclaw lives) — previously hardcoded /home/node on Linux.
    try:
        du = shutil.disk_usage(os.path.expanduser('~'))
        total_mb = round(du.total / 1024 / 1024)
        free_mb = round(du.free / 1024 / 1024)
        used_mb = total_mb - free_mb
        return {
            'disk_total_mb': total_mb,
            'disk_used_mb': used_mb,
            'disk_free_mb': free_mb,
            'disk_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0
        }
    except Exception:
        return {}

# Defaults guarantee every key the app decodes is present even if a probe fails.
result = {
    'timestamp': int(time.time()),
    'uptime_seconds': 0.0,
    'cpu_percent': 0.0,
    'ram_total_mb': 0, 'ram_used_mb': 0, 'ram_available_mb': 0, 'ram_percent': 0.0,
    'load_avg_1m': 0.0, 'load_avg_5m': 0.0,
    'disk_total_mb': 0, 'disk_used_mb': 0, 'disk_free_mb': 0, 'disk_percent': 0.0,
    'platform': 'windows' if IS_WIN else ('macos' if IS_MAC else 'linux'),
}
up = get_uptime()
if up is not None:
    result['uptime_seconds'] = up
result.update(get_cpu())
result.update(get_mem())
result.update(get_load())
result.update(get_disk())
print(json.dumps(result))
