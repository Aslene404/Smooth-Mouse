# ==============================
# Find the biggest red area on screen, move the cursor there, and click it
# Human-like motion: random arc + dramatic smooth speed changes
# Fully automatic: starts on run, exits when done
# Use Windows PowerShell 5.1
# ==============================

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class MouseControl {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("winmm.dll")]  public static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")]  public static extern uint timeEndPeriod(uint ms);

    public struct POINT { public int X; public int Y; }

    public const uint LEFTDOWN  = 0x0002;
    public const uint LEFTUP    = 0x0004;
    public const uint RIGHTDOWN = 0x0008;
    public const uint RIGHTUP   = 0x0010;
}

public class RedFinder {
    // Returns { centerX, centerY, areaInPixels } of the largest red blob, or null if none.
    public static int[] Find(int minR, int maxGB, int minAreaPx, int cell, int step) {
        int left = MouseControl.GetSystemMetrics(76);   // virtual screen left
        int top  = MouseControl.GetSystemMetrics(77);   // virtual screen top
        int w    = MouseControl.GetSystemMetrics(78);   // virtual screen width
        int h    = MouseControl.GetSystemMetrics(79);   // virtual screen height

        byte[] buf;
        int stride;
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(left, top, 0, 0, new Size(w, h));
            }
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            stride = d.Stride;
            buf = new byte[stride * h];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(d);
        }

        int gw = (w + cell - 1) / cell;
        int gh = (h + cell - 1) / cell;
        int[]  cnt = new int[gw * gh];
        long[] sx  = new long[gw * gh];
        long[] sy  = new long[gw * gh];

        // Mark red pixels (BGRA byte order)
        for (int y = 0; y < h; y += step) {
            int row = y * stride;
            int gy = (y / cell) * gw;
            for (int x = 0; x < w; x += step) {
                int i = row + x * 4;
                if (buf[i + 2] >= minR && buf[i + 1] <= maxGB && buf[i] <= maxGB) {
                    int c = gy + x / cell;
                    cnt[c]++;
                    sx[c] += x;
                    sy[c] += y;
                }
            }
        }

        // Group neighboring cells into blobs, keep the biggest
        bool[] seen = new bool[gw * gh];
        int[] queue = new int[gw * gh];
        long bestCount = 0, bestSx = 0, bestSy = 0;

        for (int s = 0; s < cnt.Length; s++) {
            if (cnt[s] == 0 || seen[s]) continue;

            int head = 0, tail = 0;
            queue[tail++] = s;
            seen[s] = true;
            long tc = 0, tx = 0, ty = 0;

            while (head < tail) {
                int c = queue[head++];
                tc += cnt[c]; tx += sx[c]; ty += sy[c];
                int cx = c % gw, cy = c / gw;

                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = cx + dx, ny = cy + dy;
                        if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
                        int n = ny * gw + nx;
                        if (!seen[n] && cnt[n] > 0) {
                            seen[n] = true;
                            queue[tail++] = n;
                        }
                    }
                }
            }

            if (tc > bestCount) { bestCount = tc; bestSx = tx; bestSy = ty; }
        }

        if (bestCount == 0) return null;
        long area = bestCount * step * step;
        if (area < minAreaPx) return null;

        return new int[] { left + (int)(bestSx / bestCount), top + (int)(bestSy / bestCount), (int)area };
    }
}
"@

# ---------- Settings ----------
# Red detection: a pixel counts as red if R >= $minRed and both G and B <= $maxGreenBlue
$minRed        = 150
$maxGreenBlue  = 90

# Ignore red areas smaller than this (in pixels)
$minAreaPx     = 150

# Seconds to keep searching before giving up (0 = search forever)
$searchTimeout = 15
$scanIntervalMs = 250

# Click settings
$clickButton   = "Left"     # "Left" or "Right"
$doubleClick   = $false     # $true = double click

# 0 = automatic duration based on distance, or a fixed number of seconds
$durationOverride = 0

# Arc bend range as a fraction of the distance
$minBend = 0.08
$maxBend = 0.40

# Number of speed events (bursts / slowdowns)
$minEvents = 2
$maxEvents = 3

# ---------- Helpers ----------
$rand = New-Object System.Random

function Get-RandRange([double]$min, [double]$max) {
    return $min + ($max - $min) * $rand.NextDouble()
}

function Clamp([double]$v, [double]$lo, [double]$hi) {
    return [Math]::Max($lo, [Math]::Min($hi, $v))
}

# One human-like click: random press duration
function Click-Once {
    if ($clickButton -eq "Right") {
        $down = [MouseControl]::RIGHTDOWN
        $up   = [MouseControl]::RIGHTUP
    }
    else {
        $down = [MouseControl]::LEFTDOWN
        $up   = [MouseControl]::LEFTUP
    }

    [MouseControl]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    [System.Threading.Thread]::Sleep([int](Get-RandRange 45 115))
    [MouseControl]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
}

function Click-Human {
    # Pause after arriving, like a person lining up the target
    [System.Threading.Thread]::Sleep([int](Get-RandRange 80 220))

    Click-Once

    if ($doubleClick) {
        [System.Threading.Thread]::Sleep([int](Get-RandRange 70 140))
        Click-Once
    }
}

function Move-Human([double]$tx, [double]$ty) {
    $vLeft = [MouseControl]::GetSystemMetrics(76)
    $vTop  = [MouseControl]::GetSystemMetrics(77)
    $vRight  = $vLeft + [MouseControl]::GetSystemMetrics(78) - 1
    $vBottom = $vTop  + [MouseControl]::GetSystemMetrics(79) - 1

    $p = New-Object MouseControl+POINT
    [void][MouseControl]::GetCursorPos([ref]$p)
    $sx = [double]$p.X
    $sy = [double]$p.Y

    $dx = $tx - $sx
    $dy = $ty - $sy
    $dist = [Math]::Sqrt($dx * $dx + $dy * $dy)

    if ($dist -lt 1) {
        Write-Host "Already at the red area."
        return
    }

    # Duration
    if ($durationOverride -gt 0) {
        $duration = [double]$durationOverride
    }
    else {
        $duration = (0.7 + 0.30 * [Math]::Log($dist / 40 + 1, 2)) * (Get-RandRange 0.9 1.3)
    }

    # Random arc (cubic Bezier)
    $ux = $dx / $dist
    $uy = $dy / $dist
    $perpX = -$uy
    $perpY = $ux

    $side = if ($rand.Next(0, 2) -eq 0) { 1 } else { -1 }
    $bend1 = $side * (Get-RandRange $minBend $maxBend) * $dist

    if ($rand.NextDouble() -lt 0.5) {
        $bend2 = $side * (Get-RandRange $minBend $maxBend) * $dist           # C-shaped
    }
    else {
        $bend2 = -$side * (Get-RandRange ($minBend * 0.6) ($maxBend * 0.8)) * $dist   # S-shaped
    }

    $f1 = Get-RandRange 0.15 0.40
    $f2 = Get-RandRange 0.60 0.85

    $c1x = Clamp ($sx + $dx * $f1 + $perpX * $bend1) $vLeft $vRight
    $c1y = Clamp ($sy + $dy * $f1 + $perpY * $bend1) $vTop  $vBottom
    $c2x = Clamp ($sx + $dx * $f2 + $perpX * $bend2) $vLeft $vRight
    $c2y = Clamp ($sy + $dy * $f2 + $perpY * $bend2) $vTop  $vBottom

    # Dramatic but smooth speed profile (integrated into a progress table)
    $eventCount = $rand.Next($minEvents, $maxEvents + 1)
    $evCenter = @(); $evWidth = @(); $evAmp = @()

    for ($i = 0; $i -lt $eventCount; $i++) {
        $lo = 0.12 + 0.76 * $i / $eventCount
        $hi = 0.12 + 0.76 * ($i + 1) / $eventCount
        $evCenter += (Get-RandRange $lo $hi)
        $evWidth  += (Get-RandRange 0.05 0.12)

        if ($rand.NextDouble() -lt 0.5) {
            $evAmp += (Get-RandRange 1.8 3.5)       # burst
        }
        else {
            $evAmp += (Get-RandRange -0.92 -0.75)   # slowdown
        }
    }

    $N = 2000
    $cum = New-Object 'double[]' ($N + 1)
    $cum[0] = 0.0
    for ($i = 1; $i -le $N; $i++) {
        $tt = ($i - 0.5) / $N
        $v = 0.04 + [Math]::Pow([Math]::Sin([Math]::PI * $tt), 0.9)
        $mod = 1.0
        for ($j = 0; $j -lt $eventCount; $j++) {
            $z = ($tt - $evCenter[$j]) / $evWidth[$j]
            $mod += $evAmp[$j] * [Math]::Exp(-0.5 * $z * $z)
        }
        $v = $v * [Math]::Max(0.08, $mod)
        $cum[$i] = $cum[$i - 1] + $v
    }
    $total = $cum[$N]
    for ($i = 0; $i -le $N; $i++) { $cum[$i] = $cum[$i] / $total }

    Write-Host ("Moving from X={0} Y={1} to X={2} Y={3} (~{4}s, {5} speed events)" -f [int]$sx, [int]$sy, [int]$tx, [int]$ty, [Math]::Round($duration, 2), $eventCount)

    # Short human reaction pause
    [System.Threading.Thread]::Sleep([int](Get-RandRange 80 220))

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastX = [int]$sx
    $lastY = [int]$sy

    while ($true) {
        $t = $watch.Elapsed.TotalSeconds / $duration
        if ($t -ge 1) { break }

        $pos = $t * $N
        $idx = [int][Math]::Floor($pos)
        $frac = $pos - $idx
        $e = $cum[$idx] + ($cum[$idx + 1] - $cum[$idx]) * $frac

        $m = 1 - $e
        $bx = $m*$m*$m*$sx + 3*$m*$m*$e*$c1x + 3*$m*$e*$e*$c2x + $e*$e*$e*$tx
        $by = $m*$m*$m*$sy + 3*$m*$m*$e*$c1y + 3*$m*$e*$e*$c2y + $e*$e*$e*$ty

        $ix = [int][Math]::Round($bx)
        $iy = [int][Math]::Round($by)

        if ($ix -ne $lastX -or $iy -ne $lastY) {
            [void][MouseControl]::SetCursorPos($ix, $iy)
            $lastX = $ix
            $lastY = $iy
        }

        [System.Threading.Thread]::Sleep(1)
    }

    [void][MouseControl]::SetCursorPos([int]$tx, [int]$ty)
}

# ---------- Main ----------
# Must run before any screen capture so coordinates match real pixels
[void][MouseControl]::SetProcessDPIAware()
[void][MouseControl]::timeBeginPeriod(1)

try {
    Write-Host "Searching for a red area..."
    $searchWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $null

    while ($true) {
        $found = [RedFinder]::Find($minRed, $maxGreenBlue, $minAreaPx, 12, 2)
        if ($found) { break }

        if ($searchTimeout -gt 0 -and $searchWatch.Elapsed.TotalSeconds -ge $searchTimeout) { break }
        [System.Threading.Thread]::Sleep($scanIntervalMs)
    }

    if (-not $found) {
        Write-Host "No red area found - exiting."
        return
    }

    Write-Host ("Red area found at X={0} Y={1} (~{2} px)" -f $found[0], $found[1], $found[2])

    Move-Human $found[0] $found[1]
    Click-Human

    Write-Host "Clicked - exiting."
}
finally {
    [void][MouseControl]::timeEndPeriod(1)
}