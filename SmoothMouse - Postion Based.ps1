# ==============================
# Smooth Human-like Mouse Movement
# Dramatic speed changes + random arc every run
# Starts at the current cursor position, moves to B, exits automatically
# ==============================

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class MouseControl {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("winmm.dll")]
    public static extern uint timeBeginPeriod(uint ms);

    [DllImport("winmm.dll")]
    public static extern uint timeEndPeriod(uint ms);

    public struct POINT {
        public int X;
        public int Y;
    }
}
"@

# ---------- Settings ----------
$targetX = 1000
$targetY = 600

# 0 = automatic duration based on distance, or a fixed number of seconds (e.g. 2.5)
$durationOverride = 0

# Arc bend range as a fraction of the distance (random within this range each run)
$minBend = 0.08
$maxBend = 0.40

# Number of speed events (bursts / slowdowns) during the motion
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

[void][MouseControl]::SetProcessDPIAware()
[void][MouseControl]::timeBeginPeriod(1)

try {
    $screenW = [MouseControl]::GetSystemMetrics(0) - 1
    $screenH = [MouseControl]::GetSystemMetrics(1) - 1

    $p = New-Object MouseControl+POINT
    [void][MouseControl]::GetCursorPos([ref]$p)
    $sx = [double]$p.X
    $sy = [double]$p.Y
    $tx = [double]$targetX
    $ty = [double]$targetY

    $dx = $tx - $sx
    $dy = $ty - $sy
    $dist = [Math]::Sqrt($dx * $dx + $dy * $dy)

    if ($dist -lt 1) {
        Write-Host "Already at destination."
        return
    }

    # ---------- Duration ----------
    if ($durationOverride -gt 0) {
        $duration = [double]$durationOverride
    }
    else {
        $duration = (0.7 + 0.30 * [Math]::Log($dist / 40 + 1, 2)) * (Get-RandRange 0.9 1.3)
    }

    # ---------- Random arc (cubic Bezier) ----------
    $ux = $dx / $dist
    $uy = $dy / $dist
    $perpX = -$uy
    $perpY = $ux

    $side = if ($rand.Next(0, 2) -eq 0) { 1 } else { -1 }
    $bend1 = $side * (Get-RandRange $minBend $maxBend) * $dist

    if ($rand.NextDouble() -lt 0.5) {
        # C-shaped arc: both control points bend the same way
        $bend2 = $side * (Get-RandRange $minBend $maxBend) * $dist
    }
    else {
        # S-shaped arc: control points bend in opposite directions
        $bend2 = -$side * (Get-RandRange ($minBend * 0.6) ($maxBend * 0.8)) * $dist
    }

    $f1 = Get-RandRange 0.15 0.40
    $f2 = Get-RandRange 0.60 0.85

    # Control points are clamped to the screen, so the whole curve stays on screen
    $c1x = Clamp ($sx + $dx * $f1 + $perpX * $bend1) 0 $screenW
    $c1y = Clamp ($sy + $dy * $f1 + $perpY * $bend1) 0 $screenH
    $c2x = Clamp ($sx + $dx * $f2 + $perpX * $bend2) 0 $screenW
    $c2y = Clamp ($sy + $dy * $f2 + $perpY * $bend2) 0 $screenH

    # ---------- Dramatic but smooth speed profile ----------
    # v(t) = bell base * (1 + gaussian bursts / slowdowns), then integrated
    # into a progress table, so position is always continuous and monotonic.
    $eventCount = $rand.Next($minEvents, $maxEvents + 1)
    $evCenter = @(); $evWidth = @(); $evAmp = @()

    $slots = 1..$eventCount | ForEach-Object { $_ }
    for ($i = 0; $i -lt $eventCount; $i++) {
        # Spread event centers across the motion so they don't all overlap
        $lo = 0.12 + 0.76 * $i / $eventCount
        $hi = 0.12 + 0.76 * ($i + 1) / $eventCount
        $evCenter += (Get-RandRange $lo $hi)
        $evWidth  += (Get-RandRange 0.05 0.12)

        if ($rand.NextDouble() -lt 0.5) {
            $evAmp += (Get-RandRange 1.8 3.5)       # burst: much faster
        }
        else {
            $evAmp += (Get-RandRange -0.92 -0.75)   # slowdown: almost a hesitation
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

    Write-Host ("From X={0} Y={1}  ->  To X={2} Y={3}  (~{4}s, {5} speed events)" -f [int]$sx, [int]$sy, $targetX, $targetY, [Math]::Round($duration, 2), $eventCount)

    # Short human reaction pause
    [System.Threading.Thread]::Sleep([int](Get-RandRange 80 220))

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastX = [int]$sx
    $lastY = [int]$sy

    while ($true) {
        $t = $watch.Elapsed.TotalSeconds / $duration
        if ($t -ge 1) { break }

        # Look up progress along the path (linear interpolation in the table)
        $pos = $t * $N
        $idx = [int][Math]::Floor($pos)
        $frac = $pos - $idx
        $e = $cum[$idx] + ($cum[$idx + 1] - $cum[$idx]) * $frac

        # Cubic Bezier position
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

    [void][MouseControl]::SetCursorPos($targetX, $targetY)
    Write-Host "Destination reached - exiting."
}
finally {
    [void][MouseControl]::timeEndPeriod(1)
}