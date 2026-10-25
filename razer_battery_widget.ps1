# Razer Battery Widget (PowerShell) - nessuna installazione richiesta
#
# Avvio widget:  doppio clic su avvia_widget.vbs   (oppure: powershell -ExecutionPolicy Bypass -File razer_battery_widget.ps1)
# Diagnosi:      powershell -ExecutionPolicy Bypass -File razer_battery_widget.ps1 -Scan
#
# Trascina con il tasto sinistro per spostarlo; tasto destro per il menu.

param([switch]$Scan)

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public class RazerReading {
    public int Pid;
    public string Name;
    public int Level = -1;      // -1 = non disponibile
    public bool Charging;
}

public static class RazerHid {
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS {
        public ushort Usage; public ushort UsagePage;
        public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.U1)] static extern bool HidD_SetFeature(SafeFileHandle h, byte[] b, int len);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.U1)] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int len);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.U1)] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.U1)] static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, out HIDP_CAPS caps);
    [DllImport("hid.dll")] [return: MarshalAs(UnmanagedType.U1)] static extern bool HidD_GetProductString(SafeFileHandle h, byte[] b, int len);

    [DllImport("setupapi.dll")] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, IntPtr e, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid g, int idx, ref SP_DEVICE_INTERFACE_DATA d);
    [DllImport("setupapi.dll")] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

    static readonly Dictionary<int, string> Names = new Dictionary<int, string> {
        { 0x00B8, "Viper V3 HyperSpeed" },
        { 0x00C0, "Viper V3 Pro (cavo)" },
        { 0x00C1, "Viper V3 Pro" },
    };
    static readonly byte[] Tids = { 0x1F, 0x3F, 0xFF, 0x9F };
    static readonly Dictionary<int, string> cachePath = new Dictionary<int, string>();
    static readonly Dictionary<int, byte> cacheTid = new Dictionary<int, byte>();

    class Iface { public string Path; public int Pid; public int UsagePage, Usage, FeatLen, InLen, OutLen; public string Product; }

    static List<string> HidPaths() {
        var list = new List<string>();
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // PRESENT | DEVICEINTERFACE
        if (set == IntPtr.Zero || set == new IntPtr(-1)) return list;
        try {
            for (int i = 0; ; i++) {
                var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                int req;
                SetupDiGetDeviceInterfaceDetailW(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                if (req <= 0) continue;
                IntPtr buf = Marshal.AllocHGlobal(req);
                try {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetailW(set, ref d, buf, req, out req, IntPtr.Zero))
                        list.Add(Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4)));
                } finally { Marshal.FreeHGlobal(buf); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return list;
    }

    static SafeFileHandle Open(string path) {
        var h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) { h.Dispose(); h = CreateFileW(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); }
        return h;
    }

    static List<Iface> RazerIfaces() {
        var res = new List<Iface>();
        foreach (var p in HidPaths()) {
            string lp = p.ToLowerInvariant();
            if (!lp.Contains("vid_1532")) continue;
            int pi = lp.IndexOf("pid_");
            if (pi < 0) continue;
            var it = new Iface { Path = p, Pid = Convert.ToInt32(lp.Substring(pi + 4, 4), 16), Product = "" };
            using (var h = Open(p)) {
                if (h.IsInvalid) continue;
                IntPtr pp;
                if (HidD_GetPreparsedData(h, out pp)) {
                    HIDP_CAPS c;
                    if (HidP_GetCaps(pp, out c) == 0x110000) {
                        it.UsagePage = c.UsagePage; it.Usage = c.Usage; it.FeatLen = c.FeatureReportByteLength;
                        it.InLen = c.InputReportByteLength; it.OutLen = c.OutputReportByteLength;
                    }
                    HidD_FreePreparsedData(pp);
                }
                var sb = new byte[256];
                if (HidD_GetProductString(h, sb, sb.Length)) it.Product = Encoding.Unicode.GetString(sb).TrimEnd('\0');
            }
            res.Add(it);
        }
        return res;
    }

    // Report Razer: [report id][status][tid][remaining x2][proto][size][class][id][args x80][crc][reserved]
    static byte[] Query(SafeFileHandle h, int len, byte tid, byte cls, byte id) {
        var b = new byte[len];
        b[2] = tid; b[6] = 0x02; b[7] = cls; b[8] = id;
        byte crc = 0;
        for (int i = 3; i < 89; i++) crc ^= b[i];
        b[89] = crc;
        if (!HidD_SetFeature(h, b, len)) return null;
        Thread.Sleep(70);
        var r = new byte[len];
        if (!HidD_GetFeature(h, r, len)) return null;
        if (r[1] != 0x02 || r[7] != cls || r[8] != id) return null;
        return r;
    }

    // ritorna {livello, in_carica, tid} oppure null
    static int[] TryRead(string path, int featLen, byte[] tids) {
        int len = featLen >= 91 ? featLen : 91;
        using (var h = Open(path)) {
            if (h.IsInvalid) return null;
            foreach (byte t in tids) {
                var r = Query(h, len, t, 0x07, 0x80);
                if (r == null) continue;
                int level = (int)Math.Round(r[10] * 100.0 / 255.0);
                var c = Query(h, len, t, 0x07, 0x84);
                return new int[] { level, (c != null && c[10] != 0) ? 1 : 0, t };
            }
        }
        return null;
    }

    // ---------------- protocollo cuffie (BlackShark HyperSpeed): report 0x02 da 64 byte
    // richiesta: d[1]=0x60|seq, d[5]=0x04, d[8]=0x80, d[9]=comando, d[61]=XOR checksum
    // 0x21 = batteria (0..100), 0x2A = ricarica (0 = no)
    static int seq = 0;

    static string Hex(byte[] d) {
        if (d == null) return "nessuna";
        var sb = new StringBuilder();
        for (int i = 0; i < 16 && i < d.Length; i++) sb.Append(d[i].ToString("X2")).Append(' ');
        return sb.ToString().Trim();
    }

    static byte[] HeadsetQuery(FileStream fs, byte cmd) {
        var b = new byte[64];
        b[0] = 0x02;                                   // report id
        b[1 + 1] = (byte)(0x60 | (seq++ & 0x1F));
        b[1 + 5] = 0x04;
        b[1 + 8] = 0x80;
        b[1 + 9] = cmd;
        byte ck = 0x02;
        for (int i = 0; i < 61; i++) ck ^= b[1 + i];
        b[1 + 61] = ck;
        fs.Write(b, 0, 64);

        var deadline = DateTime.UtcNow.AddMilliseconds(600);
        var r = new byte[64];
        while (DateTime.UtcNow < deadline) {
            var ar = fs.BeginRead(r, 0, 64, null, null);
            int ms = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
            if (ms < 1) ms = 1;
            if (!ar.AsyncWaitHandle.WaitOne(ms)) return null;   // la lettura pendente si annulla chiudendo lo stream
            int n = fs.EndRead(ar);
            if (n < 64 || r[0] != 0x02) continue;
            if (r[1 + 8] == 0x80 && r[1 + 9] == cmd) {
                var d = new byte[63];
                Array.Copy(r, 1, d, 0, 63);
                return d;
            }
        }
        return null;
    }

    static int[] TryHeadset(Iface it, StringBuilder log) {
        if (it.InLen != 64 || it.OutLen != 64) return null;
        SafeFileHandle h = CreateFileW(it.Path, 0xC0000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero); // overlapped
        if (h.IsInvalid) { h.Dispose(); if (log != null) log.Append("  [cuffia: apertura fallita]"); return null; }
        try {
            using (var fs = new FileStream(h, FileAccess.ReadWrite, 1, true)) {
                var b = HeadsetQuery(fs, 0x21);
                if (log != null) log.Append("  [cuffia batt: " + Hex(b) + "]");
                if (b == null) return null;
                var c = HeadsetQuery(fs, 0x2A);
                if (log != null) log.Append("  [cuffia carica: " + Hex(c) + "]");
                int lvl = b[12];
                if (lvl > 100) lvl = 100;
                return new int[] { lvl, (c != null && c[12] != 0) ? 1 : 0, 0 };
            }
        } catch (Exception ex) {
            if (!h.IsClosed) h.Dispose();
            if (log != null) log.Append("  [cuffia errore: " + ex.Message + "]");
            return null;
        }
    }

    static int[] TryAny(Iface it) {
        int[] r = null;
        if (it.FeatLen > 0) r = TryRead(it.Path, it.FeatLen, Tids);
        if (r == null) r = TryHeadset(it, null);
        return r;
    }

    public static List<RazerReading> ReadAll() {
        var byPid = new SortedDictionary<int, List<Iface>>();
        foreach (var it in RazerIfaces()) {
            if (!byPid.ContainsKey(it.Pid)) byPid[it.Pid] = new List<Iface>();
            byPid[it.Pid].Add(it);
        }
        var result = new List<RazerReading>();
        foreach (var kv in byPid) {
            int pid = kv.Key; var ifs = kv.Value;
            // prima le interfacce con report da 91 byte (quelle del protocollo Razer)
            ifs.Sort((a, b) => (b.FeatLen == 91 ? 1 : 0).CompareTo(a.FeatLen == 91 ? 1 : 0));

            string name;
            if (!Names.TryGetValue(pid, out name)) {
                name = "";
                foreach (var it in ifs) if (it.Product.Length > 0) { name = it.Product; break; }
                if (name.Length == 0) name = "Razer " + pid.ToString("X4");
                name = name.Replace("Razer ", "");
            }

            int[] r = null;
            if (cachePath.ContainsKey(pid)) {
                var cached = ifs.Find(x => x.Path == cachePath[pid]);
                if (cached != null) {
                    if (cacheTid[pid] == 0) r = TryHeadset(cached, null);          // 0 = protocollo cuffia
                    else r = TryRead(cached.Path, cached.FeatLen, new byte[] { cacheTid[pid] });
                }
                if (r == null) { cachePath.Remove(pid); cacheTid.Remove(pid); }
            }
            if (r == null) {
                foreach (var it in ifs) {
                    r = TryAny(it);
                    if (r != null) { cachePath[pid] = it.Path; cacheTid[pid] = (byte)r[2]; break; }
                }
            }
            var rd = new RazerReading { Pid = pid, Name = name };
            if (r != null) { rd.Level = r[0]; rd.Charging = r[1] == 1; }
            result.Add(rd);
        }
        return result;
    }

    public static string Diagnose() {
        var sb = new StringBuilder();
        var ifs = RazerIfaces();
        sb.AppendLine("Interfacce Razer trovate: " + ifs.Count);
        sb.AppendLine();
        foreach (var it in ifs) {
            string esito = "nessuna risposta";
            if (it.FeatLen > 0) {
                var r = TryRead(it.Path, it.FeatLen, Tids);
                if (r != null) esito = string.Format("{0}%  carica={1}  tid=0x{2:X2}", r[0], r[1] == 1, r[2]);
            }
            var log = new StringBuilder();
            if (it.InLen == 64 && it.OutLen == 64) {
                var h = TryHeadset(it, log);
                if (h != null) esito = string.Format("CUFFIA {0}%  carica={1}", h[0], h[1] == 1);
            }
            sb.AppendLine(string.Format("PID 0x{0:X4}  usage_page=0x{1:X4} usage=0x{2:X4}  in/out/feat={3}/{4}/{5}  {6} -> {7}{8}",
                it.Pid, it.UsagePage, it.Usage, it.InLen, it.OutLen, it.FeatLen, "'" + it.Product + "'", esito, log.ToString()));
        }
        return sb.ToString();
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

if ($Scan) {
    [RazerHid]::Diagnose()
    return
}

# ------------------------------------------------------------------ widget

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][RazerHid]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$cfgPath = Join-Path $env:APPDATA 'razer_battery_widget.json'
# mode: 'widget' = solo widget, 'tray' = solo icone nella barra, 'both' = entrambi
$cfg = @{ x = 40; y = 40; topmost = $false; mode = 'widget' }
if (Test-Path $cfgPath) {
    try {
        $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $cfg.x = [int]$j.x; $cfg.y = [int]$j.y; $cfg.topmost = [bool]$j.topmost
        if ($j.mode -in @('widget', 'tray', 'both')) { $cfg.mode = [string]$j.mode }
    } catch {}
}
function Save-Cfg { try { ($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8 } catch {} }

$cBg    = [Drawing.Color]::FromArgb(22, 24, 29)
$brFg   = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(232, 232, 232))
$brDim  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(122, 127, 136))
$brTrk  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(42, 45, 52))
$brGrn  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(68, 214, 44))
$brYel  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 194, 48))
$brRed  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 77, 77))
$fTitle = New-Object Drawing.Font('Segoe UI', 8, [Drawing.FontStyle]::Bold)
$fName  = New-Object Drawing.Font('Segoe UI', 10)
$fVal   = New-Object Drawing.Font('Segoe UI Symbol', 10, [Drawing.FontStyle]::Bold)
$sfRight = New-Object Drawing.StringFormat
$sfRight.Alignment = 'Far'

function Get-LevelBrush([int]$lvl) {
    if ($lvl -lt 0) { return $brDim }
    if ($lvl -gt 50) { return $brGrn }
    if ($lvl -gt 20) { return $brYel }
    return $brRed
}

$script:data = $null
$script:msg = 'Lettura...'
$script:barX = 160
$rowH = 26; $barW = 70; $valW = 70; $pad = 12; $top = 30

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.BackColor = $cBg
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point($cfg.x, $cfg.y)
$form.TopMost = $cfg.topmost
$form.Opacity = 0.92
$form.Size = New-Object Drawing.Size(260, 60)
$form.Text = 'Razer Battery'

function Update-Layout {
    $g = $form.CreateGraphics()
    try {
        $nameW = 120
        if ($script:data) {
            foreach ($d in $script:data) {
                $w = [int][Math]::Ceiling($g.MeasureString($d.Name, $fName).Width)
                if ($w -gt $nameW) { $nameW = $w }
            }
            $rows = $script:data.Count
        } else {
            $rows = 1
            $nameW = [Math]::Max($nameW, [int]$g.MeasureString($script:msg, $fName).Width - $barW)
        }
    } finally { $g.Dispose() }
    $script:barX = $pad + $nameW + 10
    $form.Size = New-Object Drawing.Size(($script:barX + $barW + $valW + $pad), ($top + $rows * $rowH + 8))
}

function Update-Data {
    try {
        $script:data = @([RazerHid]::ReadAll())
        $script:msg = $null
        if ($script:data.Count -eq 0) { $script:data = $null; $script:msg = 'Nessun dispositivo Razer' }
    } catch {
        $script:data = $null
        $script:msg = 'Errore: ' + $_.Exception.Message
    }
    Update-Layout
    $form.Invalidate()
    Update-Tray
}

# ------------------------------------------------------------------ icone nella barra (area di notifica)

$script:trayIcons = @{}
$brChg = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(80, 190, 255))

# disegna un'icona con il numero della percentuale
function New-LevelIcon([int]$lvl, [bool]$charging) {
    $sz = [Windows.Forms.SystemInformation]::SmallIconSize.Width
    $bmp = New-Object Drawing.Bitmap($sz, $sz)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([Drawing.Color]::Transparent)
    if ($lvl -lt 0) { $txt = '-' } else { $txt = [string][Math]::Min($lvl, 100) }
    if ($txt.Length -ge 3) { $px = $sz * 0.50 } else { $px = $sz * 0.72 }
    $f = New-Object Drawing.Font('Segoe UI', [single]$px, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($txt, $f, (Get-LevelBrush $lvl), (New-Object Drawing.RectangleF(0, 0, $sz, ($sz - 1))), $sf)
    if ($charging) { $g.FillRectangle($brChg, 1, $sz - 2, $sz - 2, 2) }   # linea azzurra = in carica
    $g.Dispose(); $f.Dispose(); $sf.Dispose()
    $icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

function Update-Tray {
    $seen = @{}
    if ($cfg.mode -ne 'widget') {
        if ($script:data) { $items = $script:data }
        else { $items = @([pscustomobject]@{ Pid = 'none'; Name = 'Razer'; Level = -1; Charging = $false }) }

        foreach ($d in $items) {
            $key = [string]$d.Pid
            $seen[$key] = $true
            $ni = $script:trayIcons[$key]
            if (-not $ni) {
                $ni = New-Object Windows.Forms.NotifyIcon
                $ni.ContextMenuStrip = $menu
                $ni.Add_DoubleClick({ Update-Data })
                $script:trayIcons[$key] = $ni
            }
            $old = $ni.Icon
            $ni.Icon = New-LevelIcon $d.Level $d.Charging
            if ($old) { [void][RazerHid]::DestroyIcon($old.Handle); $old.Dispose() }

            if ($key -eq 'none')      { $tip = $script:msg }
            elseif ($d.Level -ge 0)   { $tip = "$($d.Name): $($d.Level)%" }
            else                      { $tip = "$($d.Name): non disponibile" }
            if ($d.Charging) { $tip += ' (in carica)' }
            if (-not $tip) { $tip = 'Razer' }
            if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
            $ni.Text = $tip
            $ni.Visible = $true
        }
    }
    # rimuovi le icone dei dispositivi spariti (o tutte, in modalita' solo widget)
    foreach ($k in @($script:trayIcons.Keys)) {
        if (-not $seen[$k]) {
            $ni = $script:trayIcons[$k]
            $ni.Visible = $false
            if ($ni.Icon) { [void][RazerHid]::DestroyIcon($ni.Icon.Handle) }
            $ni.Dispose()
            $script:trayIcons.Remove($k)
        }
    }
}

function Set-Mode([string]$m) {
    $cfg.mode = $m
    Save-Cfg
    foreach ($it in $miMode.DropDownItems) { $it.Checked = ($it.Tag -eq $m) }
    $miTop.Enabled = ($m -ne 'tray')
    if ($m -eq 'tray') { $form.Hide() } else { $form.Show() }
    Update-Tray
}

$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.DrawString('RAZER', $fTitle, $brGrn, $pad, 8)
    $y = $top
    if (-not $script:data) {
        $g.DrawString($script:msg, $fName, $brDim, $pad, $y)
        return
    }
    foreach ($d in $script:data) {
        $br = Get-LevelBrush $d.Level
        $g.DrawString($d.Name, $fName, $brFg, $pad, $y)
        $g.FillRectangle($brTrk, $script:barX, $y + 8, $barW, 8)
        if ($d.Level -ge 0) {
            $g.FillRectangle($br, $script:barX, $y + 8, [int]($barW * $d.Level / 100), 8)
            $txt = "$($d.Level)%"
            if ($d.Charging) { $txt += ' ' + [char]0x26A1 }
        } else {
            $txt = [string][char]0x2014
        }
        $rect = New-Object Drawing.RectangleF(($script:barX + $barW), $y, $valW, $rowH)
        $g.DrawString($txt, $fVal, $br, $rect, $sfRight)
        $y += $rowH
    }
})

# trascinamento
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
        [void][RazerHid]::ReleaseCapture()
        [void][RazerHid]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
        $cfg.x = $form.Left; $cfg.y = $form.Top
        Save-Cfg
    }
})

# menu tasto destro
$menu = New-Object Windows.Forms.ContextMenuStrip
$miRefresh = New-Object Windows.Forms.ToolStripMenuItem('Aggiorna ora')
$miRefresh.Add_Click({ Update-Data })
$miTop = New-Object Windows.Forms.ToolStripMenuItem('Sempre in primo piano')
$miTop.CheckOnClick = $true
$miTop.Checked = $cfg.topmost
$miTop.Add_Click({ $form.TopMost = $miTop.Checked; $cfg.topmost = $miTop.Checked; Save-Cfg })
$miMode = New-Object Windows.Forms.ToolStripMenuItem('Mostra come')
foreach ($pair in @(@('widget', 'Widget sul desktop'), @('tray', 'Icone nella barra delle applicazioni'), @('both', 'Entrambi'))) {
    $it = New-Object Windows.Forms.ToolStripMenuItem($pair[1])
    $it.Tag = $pair[0]
    $it.Checked = ($cfg.mode -eq $pair[0])
    $it.Add_Click({ Set-Mode $this.Tag })
    [void]$miMode.DropDownItems.Add($it)
}
$miTop.Enabled = ($cfg.mode -ne 'tray')
$miExit = New-Object Windows.Forms.ToolStripMenuItem('Esci')
$miExit.Add_Click({ $form.Close() })
[void]$menu.Items.Add($miRefresh)
[void]$menu.Items.Add($miMode)
[void]$menu.Items.Add($miTop)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miExit)
$form.ContextMenuStrip = $menu

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-Data })

$form.Add_Shown({
    if ($cfg.mode -eq 'tray') { $form.Hide() }
    Update-Layout; $form.Refresh(); Update-Data; $timer.Start()
})

# all'uscita togli le icone dalla barra (altrimenti restano "fantasma" fino al passaggio del mouse)
$form.Add_FormClosing({
    foreach ($ni in @($script:trayIcons.Values)) { $ni.Visible = $false; $ni.Dispose() }
})
[Windows.Forms.Application]::Run($form)
