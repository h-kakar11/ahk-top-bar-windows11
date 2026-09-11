#Requires AutoHotkey v2.0

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetWinDelay(-1)
DetectHiddenWindows(true)

; ======================================================================
; CONFIG — edit these to taste
; ======================================================================
NAME_TEXT        := "NameHere"   ; put any name or any writing here
NAME_W           := 90         ; reserve for the name; widen if yours clips
TEXT_COLOR       := "ffffff"     ; pure white — maximum contrast on OLED
DIM_COLOR        := "FFFFFF"
ALERT_COLOR      := "FF5252"     ; low battery / offline only
BAR_HEIGHT       := 30
BG_COLOR         := "000000"     ; true black: OLED pixels are fully off here
; First font in this list that is actually installed wins.
FONT_STACK       := ["Perfect DOS VGA 437"]
ICON_FONT        := "Perfect DOS VGA 437"   ; falls back to MDL2 below if missing
TEXT_PT          := 9            ; one type size for everything, marquee included
NAME_PT          := 10
ICON_PT          := 11           ; every glyph icon is this size — all equal
DATE_FORMAT      := "dddd d MMMM"
; The bar is a bezel: nothing may sit on top of it — except a genuine
; fullscreen app, which should cover it exactly as it covers the taskbar.
AUTOHIDE_ON_FULLSCREEN := true
ENFORCE_TOPMOST        := true
SHOW_SYSTEM_STATS      := true
DEV_MODE         := true
; Now-playing marquee.
MARQUEE_W        := 600
FADE_W           := 44
SCROLL_PX_PER_SEC:= 120          ; scroll speed in pixels per second
MARQUEE_FPS      := 60 ;fps for marquee dont actually put your dislay monitor refresh rate as tempting as it sounds its just as smooth at 60fps. 

; ======================================================================
; STATE
; ======================================================================
global ScreenW := A_ScreenWidth
global HelperPID := 0
global AppBarRegistered := false
global BarHidden := false
global MediaText := ""
global HoverMap := Map()
global CurrentHover := 0
global PrevIdle := 0, PrevKernel := 0, PrevUser := 0
global BatteryPresent := false
global UsingMarqueePicture := false
global GdipToken := 0, GdipReady := false
global MarqueeFontFamily := 0, MarqueeFont := 0, MarqueeBrush := 0
global MarqueeText := "", MarqueeTextW := 0, MarqueeScroll := 0.0, MarqueeHBitmap := 0
global BrightnessMode := "", DdcHandle := 0, DdcArray := 0, DdcCount := 0
global DdcMin := 0, DdcMax := 100

if !FontExists(ICON_FONT)
    ICON_FONT := "Segoe MDL2 Assets"

global FONT_NAME := ResolveFont(FONT_STACK)
ResolveFont(candidates) {
    for f in candidates
        if FontExists(f)
            return f
    return "Segoe UI"
}

; Temp files are per-process, so two copies launched from different paths
; can never clobber each other's helper data.
global TmpTag := DllCall("GetCurrentProcessId")
MediaFile   := A_Temp "\ahk_topbar_media_" TmpTag ".txt"
WeatherFile := A_Temp "\ahk_topbar_weather_" TmpTag ".txt"
HelperFile  := A_Temp "\ahk_topbar_helper_" TmpTag ".ps1"

; ======================================================================
; BUILD THE BAR
; ======================================================================
; +E0x08000000 = WS_EX_NOACTIVATE — the bar can never steal keyboard focus.
Bar := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000")
Bar.BackColor := BG_COLOR
Bar.MarginX := 0, Bar.MarginY := 0

; Every control spans the full bar height and carries SS_CENTERIMAGE (0x200),
; so everything sits on one shared optical baseline regardless of type size.
TextOpt(w, color, extra := "") =>
    Format("y0 w{1} h{2} c{3} Background{4} +0x200 {5}", w, BAR_HEIGHT, color, BG_COLOR, extra)

; --- Start button: small white Windows tile ------------------------------
;SQ := 6, SQGAP := 2
;sqTop := (BAR_HEIGHT - (SQ * 2 + SQGAP)) // 2
;for pos in [[10, sqTop], [10 + SQ + SQGAP, sqTop]
;          , [10, sqTop + SQ + SQGAP], [10 + SQ + SQGAP, sqTop + SQ + SQGAP]] {
;    s := Bar.AddText(Format("x{1} y{2} w{3} h{3} Background{4}", pos[1], pos[2], SQ, TEXT_COLOR))
;    s.OnEvent("Click", (*) => Send("{LWin}"))
;}
;global startX := 10 + SQ * 2 + SQGAP + 10   ; a touch more breathing room

; WINDOWS ICON WINDOWS BUTTON ICON LOGO WINDOWS LOGO SQUARES BOXES (context for ctrl f)
; just got rid of it. windows button and icon can return by uncommenting above starting from SQ :=6... and commenting the below global startX := 10

global startX := 10

; --- Name (bold) ---------------------------------------------------------
nameCtl := Bar.AddText("x" startX " " TextOpt(NAME_W, TEXT_COLOR), NAME_TEXT)
nameCtl.SetFont("s" NAME_PT " Bold", FONT_NAME)

; --- Icon cluster: all one size, evenly spaced, temp riding along --------
wifiIcon := Bar.AddText(TextOpt(22, DIM_COLOR, "Center"), Chr(0xE701))
wifiIcon.SetFont("s" ICON_PT, ICON_FONT)
wifiIcon.OnEvent("Click", (*) => Run("ms-settings:network-wifi"))

volBtn := Bar.AddText(TextOpt(22, TEXT_COLOR, "Center"), Chr(0xE995))
volBtn.SetFont("s" ICON_PT, ICON_FONT)
volBtn.OnEvent("Click", (*) => ToggleVolumePopup())

brightBtn := Bar.AddText(TextOpt(22, TEXT_COLOR, "Center"), Chr(0xE706))
brightBtn.SetFont("s" ICON_PT, ICON_FONT)
brightBtn.OnEvent("Click", (*) => ToggleBrightnessPopup())

trayBtn := Bar.AddText(TextOpt(22, TEXT_COLOR, "Center"), Chr(0xE10C))
trayBtn.SetFont("s" ICON_PT, ICON_FONT)
trayBtn.OnEvent("Click", (*) => ShowHiddenIcons())

battIcon := Bar.AddText(TextOpt(22, DIM_COLOR, "Center"), Chr(0xE83F))
battIcon.SetFont("s" ICON_PT, ICON_FONT)
battTxt := Bar.AddText(TextOpt(42, DIM_COLOR), "")
battTxt.SetFont("s" TEXT_PT, FONT_NAME)
for c in [battIcon, battTxt]
    c.OnEvent("Click", (*) => Run("ms-settings:batterysaver"))

weatherCtl := Bar.AddText(TextOpt(58, DIM_COLOR), "…")
weatherCtl.SetFont("s" TEXT_PT, FONT_NAME)
weatherCtl.OnEvent("Click", (*) => Run("https://wttr.in"))

; --- Now playing: GDI+ marquee, same type size as everything else --------
GdipInit()
if GdipReady
    InitMarqueeResources()
if (GdipReady && MarqueeFont) {
    initHbm := 0
    try initHbm := RenderMarqueeBitmap("")
    if initHbm {
        nowPlaying := Bar.AddPicture("x0 y0 w" MARQUEE_W " h" BAR_HEIGHT, "HBITMAP:" initHbm)
        MarqueeHBitmap := initHbm
        UsingMarqueePicture := true
    }
}
if !UsingMarqueePicture {
    nowPlaying := Bar.AddText(TextOpt(MARQUEE_W, TEXT_COLOR, "Center"), "")
    nowPlaying.SetFont("s" TEXT_PT, FONT_NAME)
}

; --- Right side: load, then date, then clock -----------------------------
statsCtl := Bar.AddText(TextOpt(240, DIM_COLOR, "Right"), "")
statsCtl.SetFont("s" TEXT_PT, FONT_NAME)
statsCtl.OnEvent("Click", (*) => Run("taskmgr.exe"))

dateCtl := Bar.AddText(TextOpt(210, DIM_COLOR, "Right"), "")
dateCtl.SetFont("s" TEXT_PT, FONT_NAME)
dateCtl.OnEvent("Click", (*) => ToggleCalendar())

; Left-aligned inside a fixed box, so the hour never shifts as ms tick.
;clockCtl := Bar.AddText(TextOpt(126, TEXT_COLOR), "00:00:00.000")                               ;code 444
clockCtl := Bar.AddText(TextOpt(90, TEXT_COLOR), "00:00:00")                                    ;code 445
clockCtl.SetFont("s" NAME_PT, FONT_NAME)
clockCtl.OnEvent("Click", (*) => ToggleCalendar())

; Hover shows a tooltip only — nothing recolours, nothing uses an accent.
for c in [nameCtl, weatherCtl, battIcon, battTxt, trayBtn, volBtn]
    RegisterHover(c)
RegisterHover(wifiIcon, () => Online ? (NetName != "" ? NetName : "Connected") : "Offline")
RegisterHover(brightBtn, "Brightness")
;RegisterHover(statsCtl, () => GpuAvailable ? "" : ("GPU unavailable: " GpuInitError))                  ;code x555

InitBrightness()
if (BrightnessMode = "")
    brightBtn.Visible := false

Layout()
Bar.Show("x0 y0 w" ScreenW " h" BAR_HEIGHT " NoActivate")
if UsingMarqueePicture
    SetTimer(UpdateMarqueeFrame, Round(1000 / MARQUEE_FPS))

; ======================================================================
; LAYOUT — recomputed on startup, on display change, and when the
; battery appears/disappears (so no dead gap is left behind).
; ======================================================================
Layout() {
    global
    y := 0   ; every control is full-height and self-centres

    ; ---- Left: name, then the icon cluster, evenly spaced ----
    GAP := 10
    x := startX + NAME_W + 12
    left := [wifiIcon, volBtn]
    if brightBtn.Visible
        left.Push(brightBtn)
    left.Push(trayBtn)
    if BatteryPresent {
        left.Push(battIcon)
        left.Push(battTxt)
    }
    left.Push(weatherCtl)

    for ctl in left {
        w := (ctl = battTxt) ? 42 : (ctl = weatherCtl) ? 58 : 22
        ctl.Move(x, y)
        ; battery icon and its percentage read as one unit, so they sit tighter
        x += w + ((ctl = battIcon) ? 2 : GAP)
    }
    leftEdge := x

    ; ---- Right: right-to-left ----
    x := ScreenW - 12
    for item in [ {c: clockCtl, w: 126, g: 16}
                , {c: dateCtl,  w: 210, g: 18}
                , {c: statsCtl, w: 240, g: 0} ] {
        x -= item.w
        item.c.Move(x, y)
        x -= item.g
    }
    rightEdge := x

    ; ---- Centre: marquee, clamped so it can never collide with either side ----
    mx := (ScreenW - MARQUEE_W) // 2
    mx := Max(mx, leftEdge + 12)
    mx := Min(mx, rightEdge - 12 - MARQUEE_W)
    nowPlaying.Move(mx, y)
}

; ======================================================================
; APPBAR — reserve screen space the way Explorer expects.
; SPI_SETWORKAREA (the old approach) gets silently reset by Explorer;
; a registered appbar survives resolution changes and taskbar restarts.
; ======================================================================
global ABD := Buffer(A_PtrSize = 8 ? 48 : 36, 0)
global AB_HWND_OFF := A_PtrSize = 8 ? 8 : 4
global AB_CB_OFF   := AB_HWND_OFF + A_PtrSize
global AB_EDGE_OFF := AB_CB_OFF + 4
global AB_RC_OFF   := AB_EDGE_OFF + 4
global WM_APPBAR   := 0x0400 + 88   ; WM_USER + 88

RegisterAppBar() {
    global
    NumPut("UInt", ABD.Size, ABD, 0)
    NumPut("Ptr", Bar.Hwnd, ABD, AB_HWND_OFF)
    NumPut("UInt", WM_APPBAR, ABD, AB_CB_OFF)
    if !DllCall("Shell32\SHAppBarMessage", "UInt", 0, "Ptr", ABD, "Ptr")   ; ABM_NEW
        return false
    AppBarRegistered := true
    PositionAppBar()
    return true
}

PositionAppBar() {
    global
    if !AppBarRegistered
        return
    NumPut("UInt", 1, ABD, AB_EDGE_OFF)                 ; ABE_TOP
    NumPut("Int", 0, ABD, AB_RC_OFF + 0)
    NumPut("Int", 0, ABD, AB_RC_OFF + 4)
    NumPut("Int", ScreenW, ABD, AB_RC_OFF + 8)
    NumPut("Int", BAR_HEIGHT, ABD, AB_RC_OFF + 12)
    DllCall("Shell32\SHAppBarMessage", "UInt", 2, "Ptr", ABD, "Ptr")   ; ABM_QUERYPOS
    NumPut("Int", 0, ABD, AB_RC_OFF + 4)
    NumPut("Int", BAR_HEIGHT, ABD, AB_RC_OFF + 12)
    DllCall("Shell32\SHAppBarMessage", "UInt", 3, "Ptr", ABD, "Ptr")   ; ABM_SETPOS
    Bar.Move(0, 0, ScreenW, BAR_HEIGHT)
}

UnregisterAppBar() {
    global
    if AppBarRegistered {
        DllCall("Shell32\SHAppBarMessage", "UInt", 1, "Ptr", ABD, "Ptr")   ; ABM_REMOVE
        AppBarRegistered := false
    }
}

if !RegisterAppBar()
    ReserveWorkAreaFallback()

global OrigWorkArea := Buffer(16, 0), UsedFallback := false
ReserveWorkAreaFallback() {
    global
    rect := Buffer(16, 0)
    DllCall("SystemParametersInfo", "UInt", 0x30, "UInt", 0, "Ptr", rect, "UInt", 0)
    DllCall("RtlMoveMemory", "Ptr", OrigWorkArea, "Ptr", rect, "Ptr", 16)
    NumPut("Int", NumGet(rect, 4, "Int") + BAR_HEIGHT, rect, 4)
    DllCall("SystemParametersInfo", "UInt", 0x2F, "UInt", 0, "Ptr", rect, "UInt", 0x2)
    UsedFallback := true
}

OnMessage(WM_APPBAR, (wp, *) => (wp = 1 || wp = 2) ? PositionAppBar() : 0)
OnMessage(0x007E, HandleDisplayChange)   ; WM_DISPLAYCHANGE

HandleDisplayChange(*) {
    global ScreenW
    SetTimer(() => (ScreenW := A_ScreenWidth, Layout(), PositionAppBar()), -400)
}

; ======================================================================
; CLOCK — built by hand so milliseconds can be included. The control is
; left-aligned in a fixed box, so the hour occupies a permanently fixed
; position no matter how the tail of the string changes width.
; ======================================================================
UpdateClock() {                                                                                              ;code 445
    global clockCtl, dateCtl                                                                                 ;code 445
    clockCtl.Text := A_Hour ":" A_Min ":" A_Sec                                                              ;code 445
    dateCtl.Text := FormatTime(, DATE_FORMAT)                                                                ;code445
}                                                                                                            ;code 445
;UpdateClock() {                                                                                             ;code 444
;    global clockCtl, dateCtl                                                                                ;code 444
;    ms := A_MSec                                                                                            ;code 444
;    msStr := (ms < 10 ? "00" : ms < 100 ? "0" : "") ms                                                      ;code 444
;    clockCtl.Text := A_Hour ":" A_Min ":" A_Sec "." msStr                                                   ;code 444
;    dateCtl.Text  := FormatTime(, DATE_FORMAT)                                                              ;code 444
;}                                                                                                           ;code 444 hi
UpdateClock()
;SetTimer(UpdateClock, 50)                                                                                   ;CODE 444
SetTimer(UpdateClock, 500)                                                                                   ;CODE 445 ADDED 500MS UPDATE BUT SHOULD PROBABLY BE 1000.
; ======================================================================
; BACKGROUND HELPER — one long-lived PowerShell process feeds media info
; and weather through temp files, so the UI thread never blocks.
; ======================================================================
WriteHelperScript(path) {
    ps := "
    ( `
    param([int]$ParentPid, [string]$MediaOut, [string]$WeatherOut)
    $ErrorActionPreference = 'SilentlyContinue'
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await($task, $type) {
        $g = $asTaskGeneric.MakeGenericMethod($type)
        $n = $g.Invoke($null, @($task))
        $n.Wait(-1) | Out-Null
        $n.Result
    }
    function Save($path, $text) {
        $tmp = $path + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $text, [System.Text.Encoding]::UTF8)
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime] | Out-Null
    $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    $nextWeather = [datetime]::MinValue
    $last = [char]1
    $tick = 0
    while ($true) {
        if (($tick % 8) -eq 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        $tick++
        $line = ''
        try {
            $s = $mgr.GetCurrentSession()
            if ($s) {
                $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                $st = $s.GetPlaybackInfo().PlaybackStatus.ToString()
                $line = $st + [char]124 + $p.Artist + [char]124 + $p.Title
            }
        } catch { }
        if ($line -ne $last) { Save $MediaOut $line; $last = $line }
        if ([datetime]::Now -gt $nextWeather) {
            $nextWeather = [datetime]::Now.AddMinutes(15)
            try {
                $w = Invoke-RestMethod -Uri 'https://wttr.in/?format=%t' -UserAgent 'curl/8.0.1' -TimeoutSec 20
                Save $WeatherOut ([string]$w).Trim().TrimStart('+')
            } catch { }
        }
        Start-Sleep -Milliseconds 1200
    }
    )"
    f := FileOpen(path, "w", "UTF-8")
    f.Write(ps)
    f.Close()
}

StartHelper() {
    global HelperPID, HelperFile, MediaFile, WeatherFile
    WriteHelperScript(HelperFile)
    cmd := Format('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -ParentPid {2} -MediaOut "{3}" -WeatherOut "{4}"'
        , HelperFile, DllCall("GetCurrentProcessId"), MediaFile, WeatherFile)
    try Run(cmd, , "Hide", &pid)
    catch
        return
    HelperPID := pid
}

WatchHelper() {
    global HelperPID
    if !HelperPID || !ProcessExist(HelperPID)
        StartHelper()
}

ReadHelperOutput() {
    global nowPlaying, weatherCtl, MediaFile, WeatherFile, MediaText

    raw := ""
    try raw := Trim(FileRead(MediaFile, "UTF-8"))
    parts := StrSplit(raw, "|")
    artist := parts.Has(2) ? Trim(parts[2]) : ""
    title  := parts.Has(3) ? Trim(parts[3]) : ""

    label := title != "" ? (artist != "" ? artist " — " title : title) : ""
    if (StrLen(label) > 90)
        label := SubStr(label, 1, 89) "…"

    if (label != MediaText) {
        MediaText := label
        SetMarqueeText(label != "" ? "♪  " label : "")
    }

    w := ""
    try w := Trim(FileRead(WeatherFile, "UTF-8"))
    if (w != "" && w != weatherCtl.Text)
        weatherCtl.Text := w
}

StartHelper()
SetTimer(ReadHelperOutput, 1200)
SetTimer(WatchHelper, 15000)

; ======================================================================
; NOW-PLAYING MARQUEE — rendered with GDI+ so the scrolling title can
; genuinely alpha-fade at both edges (a plain Static control cannot).
; Every GDI+ call is wrapped: if anything fails, the marquee simply stops
; animating rather than taking the rest of the bar down with it.
; ======================================================================
GdipInit() {
    global GdipToken, GdipReady
    try {
        input := Buffer(24, 0)
        NumPut("UInt", 1, input, 0)
        r := DllCall("gdiplus\GdiplusStartup", "Ptr*", &tok := 0, "Ptr", input, "Ptr", 0)
        if (r = 0 && tok) {
            GdipToken := tok
            GdipReady := true
        }
    } catch {
        GdipReady := false
    }
}

InitMarqueeResources() {
    global MarqueeFontFamily, MarqueeFont, MarqueeBrush, FONT_NAME, TEXT_PT
    try {
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", FONT_NAME, "Ptr", 0, "Ptr*", &ff := 0)
        if !ff
            DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &ff := 0)
        MarqueeFontFamily := ff
        ; unit 3 = UnitPoint, so this matches the "s9" used everywhere else exactly
        DllCall("gdiplus\GdipCreateFont", "Ptr", ff, "Float", TEXT_PT + 0.0, "Int", 0, "Int", 3, "Ptr*", &fnt := 0)
        MarqueeFont := fnt
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFFFFFFF, "Ptr*", &br := 0)
        MarqueeBrush := br
    } catch {
        MarqueeFont := 0
    }
}

MeasureTextWidth(text) {
    global MarqueeFont
    try {
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", 1, "Int", 1, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp := 0)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g := 0)
        layout := Buffer(16, 0)
        NumPut("Float", 5000.0, layout, 8), NumPut("Float", 100.0, layout, 12)
        bbox := Buffer(16, 0)
        DllCall("gdiplus\GdipMeasureString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", MarqueeFont
            , "Ptr", layout, "Ptr", 0, "Ptr", bbox, "Int*", &fitted := 0, "Int*", &lines := 0)
        w := NumGet(bbox, 8, "Float")
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
        return Round(w)
    } catch {
        return StrLen(text) * 8
    }
}

SetMarqueeText(text) {
    global MarqueeText, MarqueeTextW, MarqueeScroll, UsingMarqueePicture, nowPlaying
    if (text = MarqueeText)
        return
    MarqueeText := text
    if !UsingMarqueePicture {
        nowPlaying.Text := text
        return
    }
    MarqueeTextW := text != "" ? MeasureTextWidth(text) : 0
    MarqueeScroll := 0.0
}

; Builds one frame; returns an HBITMAP the caller owns and must free.
RenderMarqueeBitmap(text) {
    global MarqueeFont, MarqueeBrush, MarqueeTextW, MarqueeScroll
    global MARQUEE_W, FADE_W, SCROLL_PX_PER_SEC, MARQUEE_FPS, BAR_HEIGHT

    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", MARQUEE_W, "Int", BAR_HEIGHT, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g := 0)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 5)   ; ClearType-quality AA

    if (text != "") {
        if (MarqueeTextW > MARQUEE_W - FADE_W) {
            gap := 80
            cycle := MarqueeTextW + gap
            MarqueeScroll += SCROLL_PX_PER_SEC / MARQUEE_FPS
            if (MarqueeScroll >= cycle)
                MarqueeScroll -= cycle
            drawX := MARQUEE_W - MarqueeScroll
            DrawMarqueeString(g, text, drawX)
            ; Always draw the next cycle's copy too (never conditionally) —
            ; a boundary check that flips true/false between frames as
            ; floats round differently is what caused the flicker.
            DrawMarqueeString(g, text, drawX + cycle)
        } else {
            DrawMarqueeString(g, text, (MARQUEE_W - MarqueeTextW) / 2)
        }
    }

    ; Edge fade: opaque black at the outer edge fading to transparent inward,
    ; composited over whatever text lies beneath.
    leftRect := Buffer(16, 0)
    NumPut("Int", 0, leftRect, 0), NumPut("Int", 0, leftRect, 4)
    NumPut("Int", FADE_W, leftRect, 8), NumPut("Int", BAR_HEIGHT, leftRect, 12)
    DllCall("gdiplus\GdipCreateLineBrushFromRectI", "Ptr", leftRect, "UInt", 0xFF000000, "UInt", 0x00000000
        , "Int", 0, "Int", 4, "Ptr*", &lb1 := 0)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", lb1, "Int", 0, "Int", 0, "Int", FADE_W, "Int", BAR_HEIGHT)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", lb1)

    rightRect := Buffer(16, 0)
    NumPut("Int", MARQUEE_W - FADE_W, rightRect, 0), NumPut("Int", 0, rightRect, 4)
    NumPut("Int", FADE_W, rightRect, 8), NumPut("Int", BAR_HEIGHT, rightRect, 12)
    DllCall("gdiplus\GdipCreateLineBrushFromRectI", "Ptr", rightRect, "UInt", 0x00000000, "UInt", 0xFF000000
        , "Int", 0, "Int", 4, "Ptr*", &lb2 := 0)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", lb2, "Int", MARQUEE_W - FADE_W, "Int", 0, "Int", FADE_W, "Int", BAR_HEIGHT)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", lb2)

    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bmp, "Ptr*", &hbm := 0, "UInt", 0)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    return hbm
}

DrawMarqueeString(g, text, x) {
    global MarqueeFont, MarqueeBrush, BAR_HEIGHT
    layout := Buffer(16, 0)
    NumPut("Float", x + 0.0, layout, 0)
    NumPut("Float", 0.0, layout, 4)
    NumPut("Float", 4000.0, layout, 8)
    NumPut("Float", BAR_HEIGHT + 0.0, layout, 12)
    fmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "UShort", 0, "Ptr*", &fmt)
    if fmt
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)   ; vertically centred
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1
        , "Ptr", MarqueeFont, "Ptr", layout, "Ptr", fmt, "Ptr", MarqueeBrush)
    if fmt
        DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
}

UpdateMarqueeFrame() {
    global MarqueeText, MarqueeHBitmap, nowPlaying
    try {
        newHbm := RenderMarqueeBitmap(MarqueeText)
        if !newHbm
            return
        nowPlaying.Value := "HBITMAP:" newHbm
        if MarqueeHBitmap
            DllCall("DeleteObject", "Ptr", MarqueeHBitmap)
        MarqueeHBitmap := newHbm
    } catch {
        SetTimer(UpdateMarqueeFrame, 0)   ; stop trying; last good frame stays up
    }
}

; ======================================================================

;got rid of gpu util. did not work and cant be bothered to fix it. 
;to get it back, uncomment below, and uncomment the line above that says something like RegisterHover(statsCtl, () => GpuAvailable ? "" : ("GPU unavailable: " GpuInitError)).
; to get rid of gpu util on the bar, i removed the following 

;code x554 was things i added to fix rm gpu counter
;code x555 was things i commented rm gpu counter you can use these codes to easily ctrl+f the doc

;--------
;gpu := GetGpuLoad()
;statsCtl.Text := Format("CPU {1}% RAM {2}% GPU {3}"
;    , GetCpuLoad(), GetRamLoad(), gpu >= 0 ? gpu "%" : "--")
;--------
; and replaced it with 
;statsCtl.Text := Format("CPU {1}% RAM {2}%"
;    , GetCpuLoad(), GetRamLoad())

;anyway

; GPU LOAD — via PDH performance counters (what Task Manager's GPU graph
; reads). Several counter paths are tried in turn; if all fail, the exact
; reason is kept so hovering the stats readout can report it rather than
; silently showing "--" with no explanation.
; ======================================================================
;global PdhQuery := 0, PdhCounter := 0, GpuAvailable := false, GpuInitError := "not initialised"                      all below this until next comment - code x555

;InitGpuCounter() {
;    global PdhQuery, PdhCounter, GpuAvailable, GpuInitError
;    paths := ["\GPU Engine(*engtype_3D)\Utilization Percentage"
;            , "\GPU Engine(*)\Utilization Percentage"
;            , "\GPU Adapter Memory(*)\Total Committed"]   ; last one only proves PDH works
;    try {
;        r := DllCall("pdh\PdhOpenQueryW", "Ptr", 0, "Ptr", 0, "Ptr*", &q := 0, "Int")
;        if (r != 0) {
;            GpuInitError := Format("PdhOpenQuery 0x{:X}", r & 0xFFFFFFFF)
;            return
;        }
;        PdhQuery := q
;        lastErr := 0
;        for p in paths {
;            r := DllCall("pdh\PdhAddEnglishCounterW", "Ptr", q, "WStr", p, "Ptr", 0, "Ptr*", &c := 0, "Int")
;            if (r = 0) {
;                PdhCounter := c
;                DllCall("pdh\PdhCollectQueryData", "Ptr", q)
;                GpuAvailable := true
;                GpuInitError := ""
;                return
;            }
;            lastErr := r
;        }
;        GpuInitError := Format("PdhAddCounter 0x{:X}", lastErr & 0xFFFFFFFF)
;    } catch as e {
;        GpuInitError := "exception: " e.Message
;        GpuAvailable := false
;    }
;}

;GetGpuLoad() {
;    global PdhQuery, PdhCounter, GpuAvailable
;    if !GpuAvailable
;        return -1
;    try {
;      DllCall("pdh\PdhCollectQueryData", "Ptr", PdhQuery)
;        bufSize := 0, itemCount := 0
;        DllCall("pdh\PdhGetFormattedCounterArrayW", "Ptr", PdhCounter, "UInt", 0x00000200
;            , "UInt*", &bufSize, "UInt*", &itemCount, "Ptr", 0, "Int")
;        if (bufSize <= 0)
;            return 0
;        buf := Buffer(bufSize, 0)
;        r := DllCall("pdh\PdhGetFormattedCounterArrayW", "Ptr", PdhCounter, "UInt", 0x00000200
;            , "UInt*", &bufSize, "UInt*", &itemCount, "Ptr", buf, "Int")
;        if (r != 0)
;            return 0
;        ; PDH_FMT_COUNTERVALUE_ITEM_W: LPWSTR name; DWORD CStatus; (pad); double value
;        total := 0.0, itemSize := A_PtrSize = 8 ? 24 : 16
;        valOff := A_PtrSize = 8 ? 16 : 8
;        statOff := A_PtrSize
;        Loop itemCount {
;            off := (A_Index - 1) * itemSize
;            if (NumGet(buf, off + statOff, "UInt") = 0)
;                total += NumGet(buf, off + valOff, "Double")
;        }
;        return Round(Min(100, total))
;    } catch {
;        return 0
;    }
;}                                                                                                                      code x555

; ======================================================================
; BRIGHTNESS — DDC/CI first (this is what drives an external monitor over
; the video cable), then the WMI path (which only ever works on built-in
; laptop panels). If neither is available the icon hides itself.
; Note: many monitors ship with DDC/CI switched off in their OSD menu.
; ======================================================================
InitBrightness() {
    global BrightnessMode, DdcHandle, DdcArray, DdcCount, DdcMin, DdcMax, Bar
    try {
        hmon := DllCall("MonitorFromWindow", "Ptr", Bar.Hwnd, "UInt", 2, "Ptr")   ; NEAREST
        if hmon && DllCall("dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hmon, "UInt*", &n := 0) && n {
            arr := Buffer(n * (A_PtrSize + 256), 0)
            if DllCall("dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hmon, "UInt", n, "Ptr", arr) {
                h := NumGet(arr, 0, "Ptr")
                if DllCall("dxva2\GetMonitorBrightness", "Ptr", h, "UInt*", &mn := 0, "UInt*", &cur := 0, "UInt*", &mx := 0) {
                    DdcHandle := h, DdcArray := arr, DdcCount := n
                    DdcMin := mn, DdcMax := (mx > mn ? mx : 100)
                    BrightnessMode := "ddc"
                    return
                }
                DllCall("dxva2\DestroyPhysicalMonitors", "UInt", n, "Ptr", arr)
            }
        }
    }
    try {
        for b in ComObjGet("winmgmts:\\.\root\wmi").ExecQuery("SELECT * FROM WmiMonitorBrightness") {
            BrightnessMode := "wmi"
            return
        }
    }
    BrightnessMode := ""
}

GetBrightness() {
    global BrightnessMode, DdcHandle, DdcMin, DdcMax
    if (BrightnessMode = "ddc") {
        try {
            if DllCall("dxva2\GetMonitorBrightness", "Ptr", DdcHandle, "UInt*", &mn := 0, "UInt*", &cur := 0, "UInt*", &mx := 0) {
                span := (DdcMax - DdcMin)
                return span > 0 ? Round((cur - DdcMin) * 100 / span) : cur
            }
        }
    } else if (BrightnessMode = "wmi") {
        try {
            for b in ComObjGet("winmgmts:\\.\root\wmi").ExecQuery("SELECT * FROM WmiMonitorBrightness")
                return b.CurrentBrightness
        }
    }
    return 50
}

SetBrightness(pct) {
    global BrightnessMode, DdcHandle, DdcMin, DdcMax
    pct := Max(0, Min(100, Round(pct)))
    if (BrightnessMode = "ddc") {
        try {
            raw := DdcMin + Round((DdcMax - DdcMin) * pct / 100)
            DllCall("dxva2\SetMonitorBrightness", "Ptr", DdcHandle, "UInt", raw)
        }
    } else if (BrightnessMode = "wmi") {
        try {
            for m in ComObjGet("winmgmts:\\.\root\wmi").ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods")
                m.WmiSetBrightness(1, pct)
        }
    }
}

; ======================================================================
; BATTERY / CPU / RAM / GPU readouts
; ======================================================================
UpdateSystemStats() {
    global battIcon, battTxt, statsCtl, volBtn, BatteryPresent

    sps := Buffer(12, 0)
    if DllCall("GetSystemPowerStatus", "Ptr", sps) {
        ac  := NumGet(sps, 0, "UChar")
        pct := NumGet(sps, 2, "UChar")
        present := (pct != 255)
        if (present != BatteryPresent) {
            BatteryPresent := present
            battIcon.Visible := present
            battTxt.Visible := present
            Layout()                      ; reflow so no dead gap is left behind
        }
        if present {
            charging := (ac = 1)
            idx := Min(9, Max(0, pct // 10))
            glyph := charging ? Chr(0xE85A + Min(8, idx)) : (pct >= 98 ? Chr(0xE83F) : Chr(0xE850 + idx))
            battIcon.Text := glyph
            battTxt.Text  := pct "%"
            SetColor(battIcon, (!charging && pct <= 20) ? ALERT_COLOR : DIM_COLOR)
        }
    }

    try {
        v := SoundGetVolume()
        muted := SoundGetMute()
        volBtn.Text := muted ? Chr(0xE74F)
            : v < 1  ? Chr(0xE992)
            : v < 34 ? Chr(0xE993)
            : v < 67 ? Chr(0xE994) : Chr(0xE995)
    }

    if !SHOW_SYSTEM_STATS
        return

statsCtl.Text := Format("CPU {1}% RAM {2}%"                 ;code x554
    , GetCpuLoad(), GetRamLoad())                           ;code x554

;    gpu := GetGpuLoad()                                                            code x555
;    statsCtl.Text := Format("CPU {1}%  RAM {2}%  GPU {3}"                          code x555
;        , GetCpuLoad(), GetRamLoad(), gpu >= 0 ? gpu "%" : "--")                   code x555
}

GetCpuLoad() {
    global PrevIdle, PrevKernel, PrevUser
    idle := Buffer(8, 0), kern := Buffer(8, 0), user := Buffer(8, 0)
    if !DllCall("GetSystemTimes", "Ptr", idle, "Ptr", kern, "Ptr", user)
        return 0
    i := NumGet(idle, 0, "Int64"), k := NumGet(kern, 0, "Int64"), u := NumGet(user, 0, "Int64")
    di := i - PrevIdle, dk := k - PrevKernel, du := u - PrevUser
    PrevIdle := i, PrevKernel := k, PrevUser := u
    total := dk + du                       ; kernel time already includes idle
    return total > 0 ? Round((total - di) * 100 / total) : 0
}

GetRamLoad() {
    ms := Buffer(64, 0)
    NumPut("UInt", 64, ms, 0)
    DllCall("GlobalMemoryStatusEx", "Ptr", ms)
    return NumGet(ms, 4, "UInt")
}

;InitGpuCounter()                        ;code x555
GetCpuLoad()
UpdateSystemStats()
SetTimer(UpdateSystemStats, 2000)

; ======================================================================
; NETWORK STATUS
; ======================================================================
global Online := false, NetName := ""
UpdateNetwork() {
    global wifiIcon, Online, NetName
    Online := DllCall("Wininet\InternetGetConnectedState", "UIntP", &flags := 0, "UInt", 0) ? true : false
    NetName := ""
    try {
        for nic in ComObjGet("winmgmts:").ExecQuery(
            "SELECT Name FROM Win32_NetworkAdapter WHERE NetConnectionStatus = 2") {
            NetName := nic.Name
            break
        }
    }
    wifiIcon.Text := Online ? Chr(0xE701) : Chr(0xEB55)
    SetColor(wifiIcon, Online ? DIM_COLOR : ALERT_COLOR)
}
UpdateNetwork()
SetTimer(UpdateNetwork, 20000)

; ======================================================================
; POPUPS — volume, brightness, calendar
; ======================================================================
MakePopup() {
    global BG_COLOR
    p := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x08000000")
    p.BackColor := BG_COLOR          ; true black, consistent with the bar
    return p
}

VolPopup := MakePopup()
VolPopup.SetFont("c" TEXT_COLOR " s" TEXT_PT, FONT_NAME)
volLabel := VolPopup.AddText("x12 y8 w120 Background" BG_COLOR, "Volume")
muteBtn := VolPopup.AddText("x150 y6 w24 h20 Center Background" BG_COLOR " c" TEXT_COLOR, Chr(0xE74F))
muteBtn.SetFont("s" ICON_PT, ICON_FONT)
muteBtn.OnEvent("Click", (*) => (SoundSetMute(-1), UpdateSystemStats(), RefreshVolPopup()))
volSlider := VolPopup.AddSlider("x10 y28 w170 Range0-100 NoTicks", Round(SoundGetVolume()))
volSlider.OnEvent("Change", (ctrl, *) => (SoundSetVolume(ctrl.Value), UpdateSystemStats()))
global VolPopupVisible := false

RefreshVolPopup() {
    global volSlider, volLabel
    try {
        volSlider.Value := Round(SoundGetVolume())
        volLabel.Text := "Volume  " Round(SoundGetVolume()) "%"
    }
}

ToggleVolumePopup() {
    global VolPopupVisible, VolPopup, BAR_HEIGHT, volBtn
    if VolPopupVisible {
        VolPopup.Hide(), VolPopupVisible := false
        return
    }
    CloseOtherPopups("vol")
    RefreshVolPopup()
    VolPopup.Show("x" PopupX(volBtn, 200) " y" (BAR_HEIGHT + 2) " w200 h64 NoActivate")
    VolPopupVisible := true
    SetTimer(AutoHidePopups, 400)
}

BrightPopup := MakePopup()
BrightPopup.SetFont("c" TEXT_COLOR " s" TEXT_PT, FONT_NAME)
brightLabel := BrightPopup.AddText("x12 y8 w170 Background" BG_COLOR, "Brightness")
brightSlider := BrightPopup.AddSlider("x10 y28 w170 Range0-100 NoTicks", 50)
brightSlider.OnEvent("Change", (ctrl, *) => (SetBrightness(ctrl.Value)
    , brightLabel.Text := "Brightness  " ctrl.Value "%"))
global BrightPopupVisible := false

ToggleBrightnessPopup() {
    global BrightPopupVisible, BrightPopup, BAR_HEIGHT, brightSlider, brightLabel, brightBtn
    if BrightPopupVisible {
        BrightPopup.Hide(), BrightPopupVisible := false
        return
    }
    CloseOtherPopups("bright")
    cur := GetBrightness()
    brightSlider.Value := cur
    brightLabel.Text := "Brightness  " cur "%"
    BrightPopup.Show("x" PopupX(brightBtn, 200) " y" (BAR_HEIGHT + 2) " w200 h64 NoActivate")
    BrightPopupVisible := true
    SetTimer(AutoHidePopups, 400)
}

CalPopup := MakePopup()
CalPopup.AddMonthCal("x4 y4")
global CalVisible := false

ToggleCalendar() {
    global CalVisible, CalPopup, ScreenW, BAR_HEIGHT
    if CalVisible {
        HideCalendar()
        return
    }
    CloseOtherPopups("cal")
    CalPopup.Show("x" (ScreenW - 250) " y" (BAR_HEIGHT + 2) " AutoSize NoActivate")
    CalVisible := true
    SetTimer(AutoHidePopups, 400)
}
HideCalendar() {
    global CalVisible, CalPopup
    if CalVisible
        CalPopup.Hide(), CalVisible := false
}

CloseOtherPopups(keep) {
    global VolPopupVisible, BrightPopupVisible, CalVisible
    if (keep != "vol" && VolPopupVisible)
        ToggleVolumePopup()
    if (keep != "bright" && BrightPopupVisible)
        ToggleBrightnessPopup()
    if (keep != "cal" && CalVisible)
        HideCalendar()
}

; Anchor a popup under its icon, nudged inward so it can't run off-screen.
PopupX(ctl, w) {
    global ScreenW
    ctl.GetPos(&cx)
    return Max(4, Min(ScreenW - w - 4, cx - w // 2 + 11))
}

global AwayTicks := 0
AutoHidePopups() {
    global AwayTicks, VolPopupVisible, BrightPopupVisible, CalVisible
    if (!VolPopupVisible && !BrightPopupVisible && !CalVisible) {
        SetTimer(AutoHidePopups, 0)
        return
    }
    MouseGetPos(, , &win)
    over := (win = Bar.Hwnd)
        || (VolPopupVisible && win = VolPopup.Hwnd)
        || (BrightPopupVisible && win = BrightPopup.Hwnd)
        || (CalVisible && win = CalPopup.Hwnd)
    AwayTicks := over ? 0 : AwayTicks + 1
    if (AwayTicks >= 4) {                    ; ~1.6s outside
        AwayTicks := 0
        if VolPopupVisible
            ToggleVolumePopup()
        if BrightPopupVisible
            ToggleBrightnessPopup()
        HideCalendar()
    }
}

; Wheel over an icon adjusts it directly, no popup needed.
#HotIf MouseIsOverControl(volBtn)
WheelUp::AdjustVolume(2)
WheelDown::AdjustVolume(-2)
#HotIf

#HotIf MouseIsOverControl(brightBtn)
WheelUp::AdjustBrightness(5)
WheelDown::AdjustBrightness(-5)
#HotIf

AdjustVolume(delta) {
    try {
        SoundSetVolume(Max(0, Min(100, Round(SoundGetVolume()) + delta)))
        UpdateSystemStats()
        if VolPopupVisible
            RefreshVolPopup()
    }
}

AdjustBrightness(delta) {
    global brightSlider, brightLabel, BrightPopupVisible
    v := Max(0, Min(100, GetBrightness() + delta))
    SetBrightness(v)
    if BrightPopupVisible {
        brightSlider.Value := v
        brightLabel.Text := "Brightness  " v "%"
    }
}

MouseIsOverControl(ctl) {
    MouseGetPos(, , &win, &ctrlHwnd, 2)
    return win = Bar.Hwnd && ctrlHwnd = ctl.Hwnd
}

; ======================================================================
; HOVER — tooltip only; nothing in the bar recolours on hover.
; ======================================================================
RegisterHover(ctl, hint := "") {
    global HoverMap
    HoverMap[ctl.Hwnd] := {ctl: ctl, hint: hint}
}

SetColor(ctl, color) {
    ctl.Opt("c" color)
    ctl.Redraw()
}

TrackHover() {
    global HoverMap, CurrentHover, Bar
    MouseGetPos(, , &win, &hw, 2)
    target := (win = Bar.Hwnd && HoverMap.Has(hw)) ? hw : 0
    if (target = CurrentHover)
        return
    ToolTip()
    if target {
        e := HoverMap[target]
        if e.hint {
            txt := HasMethod(e.hint, "Call") ? e.hint.Call() : e.hint
            if (txt != "")
                ToolTip(txt)
        }
    }
    CurrentHover := target
}
SetTimer(TrackHover, 120)

; ======================================================================
; BEZEL BEHAVIOUR — this strip belongs to the bar and nothing else.
;   1. The appbar registration removes the strip from the desktop work
;      area, so maximised and snapped windows never extend into it.
;   2. This re-asserts z-order when a *topmost* window tries to draw over
;      it anyway. Several points across the width are sampled, since a
;      window can cover one end without touching the centre pixel.
; Exclusive-fullscreen games bypass the desktop compositor entirely at
; the driver level; nothing on the desktop can draw over that, which is
; an OS/GPU limitation rather than something this can work around.
; ======================================================================
EnforceTopmost() {
    global Bar, BarHidden, ScreenW, BAR_HEIGHT
    static HWND_TOPMOST := -1
         , SWP_NOSIZE := 0x1, SWP_NOMOVE := 0x2, SWP_NOACTIVATE := 0x10
    if BarHidden
        return
    y := BAR_HEIGHT // 2
    covered := false
    for frac in [0.03, 0.25, 0.5, 0.75, 0.97] {
        x := Round(ScreenW * frac)
        hw := DllCall("WindowFromPoint", "Int64", (y << 32) | (x & 0xFFFFFFFF), "Ptr")
        if !hw
            continue
        if (DllCall("GetAncestor", "Ptr", hw, "UInt", 2, "Ptr") != Bar.Hwnd) {
            covered := true
            break
        }
    }
    if !covered
        return
    DllCall("SetWindowPos", "Ptr", Bar.Hwnd, "Ptr", HWND_TOPMOST
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
}
if ENFORCE_TOPMOST
    SetTimer(EnforceTopmost, 250)

; ======================================================================
; AUTO-HIDE OVER FULLSCREEN APPS (off by default)
; ======================================================================
CheckFullscreen() {
    global BarHidden, Bar
    if !AUTOHIDE_ON_FULLSCREEN
        return
    want := IsFullscreenActive()
    if (want = BarHidden)
        return
    BarHidden := want
    if want
        Bar.Hide()
    else
        Bar.Show("NoActivate")
}

IsFullscreenActive() {
    global Bar, VolPopup, CalPopup, BrightPopup
    hwnd := WinExist("A")
    if !hwnd || hwnd = Bar.Hwnd || hwnd = VolPopup.Hwnd || hwnd = CalPopup.Hwnd || hwnd = BrightPopup.Hwnd
        return false
    try cls := WinGetClass(hwnd)
    catch
        return false
    if (cls = "WorkerW" || cls = "Progman" || cls = "Shell_TrayWnd" || cls = "Windows.UI.Core.CoreWindow")
        return false
    try WinGetPos(&x, &y, &w, &h, hwnd)
    catch
        return false
    return (x <= 0 && y <= 0 && w >= A_ScreenWidth && h >= A_ScreenHeight)
}
if AUTOHIDE_ON_FULLSCREEN
    SetTimer(CheckFullscreen, 400)

; ======================================================================
; SHOW HIDDEN TRAY ICONS
; UI Automation first — it reaches the button even on builds where the
; overflow is drawn by a XAML host rather than a classic Win32 control.
; Then the old control-text search, then Win+B *plus Enter* (Win+B alone
; only moves focus to the button; it never opens the flyout).
; ======================================================================
ShowHiddenIcons() {
    if UIAInvokeTrayOverflow()
        return
    try {
        if trayHwnd := WinExist("ahk_class Shell_TrayWnd") {
            for ctrlHwnd in WinGetControlsHwnd("ahk_id " trayHwnd) {
                try {
                    if InStr(ControlGetText(ctrlHwnd), "hidden icons") {
                        ControlClick(ctrlHwnd)
                        return
                    }
                }
            }
        }
    }
    Send("{LWin down}b{LWin up}")
    Sleep(80)
    Send("{Enter}")
}

; Matches the English accessible name; on a non-English Windows this
; falls through to the other two strategies instead.
UIAInvokeTrayOverflow() {
    static CLSID := "{FF48DBA4-60EF-4201-AA87-54103EEF594E}"
    static IID   := "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}"
    static UIA_NamePropertyId  := 30005
    static UIA_InvokePatternId := 10000
    static TreeScope_Descendants := 4

    trayHwnd := WinExist("ahk_class Shell_TrayWnd")
    if !trayHwnd
        return false

    for label in ["Show hidden icons", "Hidden icons", "Notification Chevron"] {
        try {
            iua := ComObject(CLSID, IID)
            bstr := DllCall("oleaut32\SysAllocString", "Str", label, "Ptr")
            variant := Buffer(8 + A_PtrSize * 2, 0)
            NumPut("UShort", 8, variant, 0)
            NumPut("Ptr", bstr, variant, 8)

            ComCall(6, iua, "Ptr", trayHwnd, "Ptr*", &root := 0, "HRESULT")
            if !root {
                DllCall("oleaut32\SysFreeString", "Ptr", bstr)
                continue
            }
            ComCall(23, iua, "Int", UIA_NamePropertyId, "Ptr", variant, "Ptr*", &cond := 0, "HRESULT")
            ComCall(5, root, "Int", TreeScope_Descendants, "Ptr", cond, "Ptr*", &el := 0, "HRESULT")

            DllCall("oleaut32\SysFreeString", "Ptr", bstr)
            ComCall(2, cond)
            ComCall(2, root)

            if !el
                continue

            ComCall(16, el, "Int", UIA_InvokePatternId, "Ptr*", &pattern := 0, "HRESULT")
            ComCall(2, el)
            if !pattern
                continue

            ComCall(3, pattern, "HRESULT")
            ComCall(2, pattern)
            return true
        }
    }
    return false
}

; ======================================================================
; MISC HELPERS
; ======================================================================
FontExists(name) {
    static installed := ""
    if (installed = "") {
        installed := ""
        try {
            for key in ["HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
                      , "HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"]
                Loop Reg, key
                    installed .= "|" A_LoopRegName
        }
    }
    return InStr(installed, name)
}

; ======================================================================
; TRAY MENU
; ======================================================================
StartupLink() => A_Startup "\TopBar.lnk"
ToggleStartup(item, *) {
    if FileExist(StartupLink()) {
        FileDelete(StartupLink())
        A_TrayMenu.Uncheck(item)
    } else {
        FileCreateShortcut(A_IsCompiled ? A_ScriptFullPath : A_AhkPath, StartupLink()
            , A_ScriptDir, A_IsCompiled ? "" : '"' A_ScriptFullPath '"')
        A_TrayMenu.Check(item)
    }
}

A_TrayMenu.Delete()
A_TrayMenu.Add("Reload bar", (*) => Reload())
A_TrayMenu.Add("Start with Windows", ToggleStartup)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Reload bar"
if FileExist(StartupLink())
    A_TrayMenu.Check("Start with Windows")

; ======================================================================
; DEV MODE — reload ~1s after the file is saved
; ======================================================================
global LastScriptModTime := FileGetTime(A_ScriptFullPath, "M")
CheckForScriptChanges() {
    global LastScriptModTime
    try {
        if (FileGetTime(A_ScriptFullPath, "M") != LastScriptModTime)
            Reload()
    }
}
if DEV_MODE
    SetTimer(CheckForScriptChanges, 1000)

; ======================================================================
; CLEANUP — give the screen space back, release every handle
; ======================================================================
OnExit(Cleanup)
Cleanup(*) {
    global HelperPID, UsedFallback, OrigWorkArea, MarqueeHBitmap
    global MarqueeFont, MarqueeFontFamily, MarqueeBrush, GdipToken, GdipReady
;    global PdhQuery, DdcArray, DdcCount, BrightnessMode                            code x555

    UnregisterAppBar()
    if UsedFallback
        DllCall("SystemParametersInfo", "UInt", 0x2F, "UInt", 0, "Ptr", OrigWorkArea, "UInt", 0x2)
    if HelperPID
        try ProcessClose(HelperPID)
    for f in [MediaFile, WeatherFile, HelperFile]
        try FileDelete(f)

    if MarqueeHBitmap
        try DllCall("DeleteObject", "Ptr", MarqueeHBitmap)
    if GdipReady {
        try {
            if MarqueeBrush
                DllCall("gdiplus\GdipDeleteBrush", "Ptr", MarqueeBrush)
            if MarqueeFont
                DllCall("gdiplus\GdipDeleteFont", "Ptr", MarqueeFont)
            if MarqueeFontFamily
                DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", MarqueeFontFamily)
            DllCall("gdiplus\GdiplusShutdown", "Ptr", GdipToken)
        }
    }
;    if PdhQuery                                                                             ;code x555
;        try DllCall("pdh\PdhCloseQuery", "Ptr", PdhQuery)                                   ;code x555
    if (BrightnessMode = "ddc" && DdcArray)
        try DllCall("dxva2\DestroyPhysicalMonitors", "UInt", DdcCount, "Ptr", DdcArray)
}




; i removed miliseconds from the clock. think its too overdone and too extra. 
;code 444 denotes the removal of lines for this.
;code 445 denotes the addition to counteract the removal of the lines.