import os
import posix

import navigation
import screenshot
import config

import x11/xlib,
       x11/x,
       x11/xutil,
       x11/keysym,
       x11/xrandr,
       x11/cursorfont
import opengl, opengl/glx
import la
import strutils
import math
import options

type Shader = tuple[path, content: string]

proc readShader(file: string): Shader =
  when nimvm:
    result.path = file
    result.content = slurp result.path
  else:
    result.path = "src" / file
    result.content = readFile result.path

when defined(developer):
  var
    vertexShader = readShader "vert.glsl"
    fragmentShader = readShader "frag.glsl"

  proc reloadShader(shader: var Shader) =
    shader.content = readFile shader.path
else:
  const
    vertexShader = readShader "vert.glsl"
    fragmentShader = readShader "frag.glsl"

proc newShader(shader: Shader, kind: GLenum): GLuint =
  result = glCreateShader(kind)
  var shaderArray = allocCStringArray([shader.content])
  glShaderSource(result, 1, shaderArray, nil)
  glCompileShader(result)
  deallocCStringArray(shaderArray)

  var success: GLint
  var infoLog = newString(512).cstring
  glGetShaderiv(result, GL_COMPILE_STATUS, addr success)
  if not success.bool:
    glGetShaderInfoLog(result, 512, nil, infoLog)
    echo "------------------------------"
    echo "Error during shader compilation: ", shader.path, ". Log:"
    echo infoLog
    echo "------------------------------"

proc newShaderProgram(vertex, fragment: Shader): GLuint =
  result = glCreateProgram()

  var
    vertexShader = newShader(vertex, GL_VERTEX_SHADER)
    fragmentShader = newShader(fragment, GL_FRAGMENT_SHADER)

  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)

  glLinkProgram(result)

  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)

  var success: GLint
  var infoLog = newString(512).cstring
  glGetProgramiv(result, GL_LINK_STATUS, addr success)
  if not success.bool:
    glGetProgramInfoLog(result, 512, nil, infoLog)
    echo infoLog

  glUseProgram(result)

type Flashlight = object
  isEnabled: bool
  shadow: float32
  radius: float32
  deltaRadius: float32

const
  INITIAL_FL_DELTA_RADIUS = 250.0
  FL_DELTA_RADIUS_DECELERATION = 10.0

proc update(flashlight: var Flashlight, dt: float32) =
  if abs(flashlight.deltaRadius) > 1.0:
    flashlight.radius = max(0.0, flashlight.radius + flashlight.deltaRadius * dt)
    flashlight.deltaRadius -= flashlight.deltaRadius * FL_DELTA_RADIUS_DECELERATION * dt

  if flashlight.isEnabled:
    flashlight.shadow = min(flashlight.shadow + 6.0 * dt, 0.8)
  else:
    flashlight.shadow = max(flashlight.shadow - 6.0 * dt, 0.0)

proc draw(screenshot: PXImage, camera: Camera, shader, vao, texture: GLuint,
          windowSize: Vec2f, mouse: Mouse, flashlight: Flashlight, mirror: bool) =
  glClearColor(0.1, 0.1, 0.1, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  glUseProgram(shader)

  glUniform2f(glGetUniformLocation(shader, "cameraPos".cstring), camera.position[0], camera.position[1])
  glUniform1f(glGetUniformLocation(shader, "cameraScale".cstring), camera.scale)
  glUniform2f(glGetUniformLocation(shader, "screenshotSize".cstring),
              screenshot.width.float32,
              screenshot.height.float32)
  glUniform2f(glGetUniformLocation(shader, "windowSize".cstring),
              windowSize.x.float32,
              windowSize.y.float32)
  glUniform2f(glGetUniformLocation(shader, "cursorPos".cstring),
              mouse.curr.x.float32,
              mouse.curr.y.float32)
  glUniform1f(glGetUniformLocation(shader, "flShadow".cstring), flashlight.shadow)
  glUniform1f(glGetUniformLocation(shader, "flRadius".cstring), flashlight.radius)
  glUniform1i(glGetUniformLocation(shader, "mirror".cstring), if mirror: 1 else: 0)

  glBindVertexArray(vao)
  glDrawElements(GL_TRIANGLES, count = 6, GL_UNSIGNED_INT, indices = nil)

proc getCursorPosition(display: PDisplay): Vec2f =
  var root, child: Window
  var root_x, root_y, win_x, win_y: cint
  var mask: cuint
  discard XQueryPointer(
    display, DefaultRootWindow(display),
    addr root, addr child,
    addr root_x, addr root_y,
    addr winX, addr winY,
    addr mask);
  result.x = root_x.float32
  result.y = root_y.float32

proc selectWindow(display: PDisplay): Window =
  var cursor = XCreateFontCursor(display, XC_crosshair)
  defer: discard XFreeCursor(display, cursor)

  var root = DefaultRootWindow(display)
  discard XGrabPointer(display, root, 0,
                       ButtonMotionMask or
                       ButtonPressMask or
                       ButtonReleaseMask,
                       GrabModeAsync, GrabModeAsync,
                       root, cursor,
                       CurrentTime)
  defer: discard XUngrabPointer(display, CurrentTime)

  discard XGrabKeyboard(display, root, 0,
                        GrabModeAsync, GrabModeAsync,
                        CurrentTime)
  defer: discard XUngrabKeyboard(display, CurrentTime)

  var event: XEvent
  while true:
    discard XNextEvent(display, addr event)
    case event.theType
    of ButtonPress:
      return event.xbutton.subwindow
    of KeyPress:
      return root
    else:
      discard

  return root

proc xElevenErrorHandler(display: PDisplay, errorEvent: PXErrorEvent): cint{.cdecl.} =
  const CAPACITY = 256
  var errorMessage: array[CAPACITY, char]
  discard XGetErrorText(display, errorEvent.error_code.cint, cast[cstring](addr errorMessage), CAPACITY)
  echo "X ELEVEN ERROR: ", $(cast[cstring](addr errorMessage))

var gQuit = false

proc onSignal(sig: cint) {.noconv.} =
  gQuit = true

# Live mode talks to a picom patched with picom-zoom.patch through root window
# properties: _BOOMER_ZOOM_ACK (set by picom) and _BOOMER_ZOOM (set by us).
proc picomZoomAck(display: PDisplay): bool =
  let ack = XInternAtom(display, "_BOOMER_ZOOM_ACK", 0)
  for _ in 0 ..< 10:
    var
      actualType: Atom
      actualFormat: cint
      nItems, bytesAfter: culong
      data: ptr cuchar
    discard XGetWindowProperty(display, DefaultRootWindow(display), ack, 0, 1, 0,
                               AnyPropertyType, addr actualType, addr actualFormat,
                               addr nItems, addr bytesAfter, addr data)
    var alive = false
    if data != nil:
      # picom stores its pid; a leftover from a picom that died doesn't count
      if nItems.int > 0 and actualFormat == 32:
        alive = dirExists("/proc/" & $(cast[ptr clong](data)[]))
      discard XFree(data)
    if alive:
      return true
    sleep(10)
  false

proc setPicomZoom(display: PDisplay, scale: float32, x, y: int) =
  var v = [clong(scale * 1000.0), clong(x), clong(y)]
  discard XChangeProperty(display, DefaultRootWindow(display),
                          XInternAtom(display, "_BOOMER_ZOOM", 0), Atom(6), 32,
                          PropModeReplace, cast[PCUChar](addr v[0]), 3)
  discard XFlush(display)

proc clearPicomZoom(display: PDisplay) =
  discard XDeleteProperty(display, DefaultRootWindow(display),
                          XInternAtom(display, "_BOOMER_ZOOM", 0))
  discard XFlush(display)

# Live mode flashlight: picom draws the screen, so the dimming is a separate
# 32-bit ARGB window under our input window. Pixel = premultiplied black at
# `alpha`, with a fully transparent circle. Picom zooms it with everything else,
# so all coordinates here are unzoomed screen pixels.
proc drawFlashlightOverlay(display: PDisplay, overlay: Window, gc: GC,
                           w, h: cuint, cx, cy, radius: float32, alpha: float32) =
  let dim = culong(clamp(int(alpha * 255.0), 0, 255)) shl 24
  discard XSetForeground(display, gc, dim)
  discard XFillRectangle(display, overlay, gc, 0, 0, w, h)
  discard XSetForeground(display, gc, 0)
  let r = max(int(radius), 0)
  discard XFillArc(display, overlay, gc, cint(int(cx) - r), cint(int(cy) - r),
                   cuint(2 * r), cuint(2 * r), 0, 360 * 64)

proc main() =
  let boomerDir = getConfigDir() / "boomer"
  var configFile = boomerDir / "config"
  var windowed = false
  var live = false
  var delaySec = 0.0

  # TODO(#95): Make boomer optionally wait for some kind of event (for example, key press)
  block:
    proc versionQuit() =
      const hash = gorgeEx("git rev-parse HEAD")
      quit "boomer-$#" % [if hash.exitCode == 0: hash.output[0 .. 7] else: "unknown"]
    proc usageQuit() =
      quit """Usage: boomer [OPTIONS]
  -d, --delay <seconds: float>  delay execution of the program by provided <seconds>
  -h, --help                    show this help and exit
      --new-config [filepath]   generate a new default config at [filepath]
  -c, --config <filepath>       use config at <filepath>
  -V, --version                 show the current version and exit
  -w, --windowed                windowed mode instead of fullscreen
  -L, --live                    zoom the live screen (needs the patched picom)"""
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)

      template asParam(paramVar: untyped, body: untyped) =
        if i + 1 > paramCount():
          echo "No value is provided for $#" % [arg]
          usageQuit()
        let paramVar = paramStr(i + 1)
        body
        i += 2

      template asFlag(body: untyped) =
        body
        i += 1

      template asOptionalParam(paramVar: untyped, body: untyped) =
        let paramVar = block:
          var resultVal = none(string)
          if i + 1 <= paramCount():
            let param = paramStr(i + 1)
            if len(param) > 0 and param[0] != '-':
              resultVal = some(param)
          resultVal
        body
        if paramVar.isNone:
          i += 1
        else:
          i += 2

      case arg
      of "-d", "--delay":
        asParam(delayParam):
          delaySec = parseFloat(delayParam)
      of "-L", "--live":
        asFlag():
          live = true
      of "-w", "--windowed":
        asFlag():
          windowed = true
      of "-h", "--help":
        asFlag():
          usageQuit()
      of "-V", "--version":
        asFlag():
          versionQuit()
      of "--new-config":
        asOptionalParam(configName):
          let newConfigPath = configName.get(configFile)

          createDir(newConfigPath.splitFile.dir)
          if newConfigPath.fileExists:
            stdout.write("File ", newConfigPath, " already exists. Replace it? [yn] ")
            if stdin.readChar != 'y':
              quit "Disaster prevented"

          generateDefaultConfig(newConfigPath)
          quit "Generated config at $#" % [newConfigPath]
      of "-c", "--config":
        asParam(configParam):
          configFile = configParam
      else:
        echo "Unknown flag `$#`" % [arg]
        usageQuit()
  sleep(floor(delaySec * 1000).int)

  var config = defaultConfig

  if fileExists configFile:
    config = loadConfig(configFile)
  else:
    stderr.writeLine configFile & " doesn't exist. Using default values. "

  echo "Using config: ", config

  var display = XOpenDisplay(nil)
  if display == nil:
    quit "Failed to open display"
  defer:
    discard XCloseDisplay(display)

  discard XSetErrorHandler(xElevenErrorHandler)

  if live and not picomZoomAck(display):
    echo "No patched picom found, falling back to the static screenshot"
    live = false
  if live:
    signal(SIGTERM, onSignal)
    signal(SIGINT, onSignal)
    signal(SIGHUP, onSignal)
  defer:
    if live:
      clearPicomZoom(display)

  when defined(select):
    echo "Please select window:"
    var trackingWindow = selectWindow(display)
  else:
    var trackingWindow = DefaultRootWindow(display)

  var screenConfig = XRRGetScreenInfo(display, DefaultRootWindow(display))
  let rate = XRRConfigCurrentRate(screenConfig)
  echo "Screen rate: ", rate

  let screen = XDefaultScreen(display)
  var glxMajor, glxMinor: cint

  if (not glXQueryVersion(display, glxMajor, glxMinor).bool or
      (glxMajor == 1.cint and glxMinor < 3.cint) or
      (glxMajor < 1.cint)):
    quit "Invalid GLX version. Expected >=1.3"
  echo("GLX version ", glxMajor, ".", glxMinor)
  echo("GLX extension: ", glXQueryExtensionsString(display, screen))

  var attrs = [
    GLX_RGBA,
    GLX_DEPTH_SIZE, 24,
    GLX_DOUBLEBUFFER,
    None
  ]

  var vi = glXChooseVisual(display, 0, addr attrs[0])
  if vi == nil:
    quit "No appropriate visual found"


  echo "Visual ", vi.visualid, " selected"
  var swa: XSetWindowAttributes
  swa.colormap = XCreateColormap(display, DefaultRootWindow(display),
                                 vi.visual, AllocNone)
  swa.event_mask = ButtonPressMask or ButtonReleaseMask or
                   KeyPressMask or KeyReleaseMask or
                   PointerMotionMask or ExposureMask or ClientMessage
  if not windowed:
    swa.override_redirect = 1
    swa.save_under = 1

  var attributes: XWindowAttributes
  discard XGetWindowAttributes(
    display,
    DefaultRootWindow(display),
    addr attributes)
  var win = XCreateWindow(
    display, DefaultRootWindow(display),
    0, 0, attributes.width.cuint, attributes.height.cuint, 0,
    vi.depth, InputOutput, vi.visual,
    CWColormap or CWEventMask or CWOverrideRedirect or CWSaveUnder, addr swa)

  # In live mode the GL window stays unmapped; a transparent input-only window
  # takes the keyboard and mouse while picom draws the zoomed screen.
  var focusWin = win
  if live:
    var iwa: XSetWindowAttributes
    iwa.event_mask = swa.event_mask
    iwa.override_redirect = 1
    focusWin = XCreateWindow(
      display, DefaultRootWindow(display),
      0, 0, attributes.width.cuint, attributes.height.cuint, 0,
      0, InputOnly, nil,
      CWEventMask or CWOverrideRedirect, addr iwa)
    discard XMapWindow(display, focusWin)
    # Grab the keyboard once. Re-taking focus every frame (as the static mode
    # does) makes Emacs flip between active/inactive faces, which flickers.
    # The window manager may still hold the grab of the key that launched us
    # (e.g. s-Z), so retry for a moment before giving up.
    var grabbed = false
    for _ in 0 ..< 100:
      if XGrabKeyboard(display, focusWin, 0, GrabModeAsync, GrabModeAsync,
                       CurrentTime) == GrabSuccess:
        grabbed = true
        break
      sleep(20)
    if not grabbed:
      stderr.writeLine "boomer: could not grab the keyboard, falling back to focus"
      discard XSetInputFocus(display, focusWin, RevertToParent, CurrentTime)
  else:
    discard XMapWindow(display, win)

  var
    overlay: Window = 0
    overlayGc: GC = nil
    overlayMapped = false
    overlayKey = (cx: -1, cy: -1, r: -1, a: -1)
  if live:
    var vinfo: XVisualInfo
    if XMatchVisualInfo(display, screen, 32, TrueColor, addr vinfo) != 0:
      var owa: XSetWindowAttributes
      owa.colormap = XCreateColormap(display, DefaultRootWindow(display),
                                     vinfo.visual, AllocNone)
      owa.border_pixel = 0
      owa.background_pixel = 0
      owa.override_redirect = 1
      overlay = XCreateWindow(
        display, DefaultRootWindow(display),
        0, 0, attributes.width.cuint, attributes.height.cuint, 0,
        32, InputOutput, vinfo.visual,
        CWColormap or CWBorderPixel or CWBackPixel or CWOverrideRedirect, addr owa)
      overlayGc = XCreateGC(display, overlay, 0, nil)
    else:
      stderr.writeLine "boomer: no 32-bit visual, flashlight is unavailable in live mode"

  var wmName = "boomer"
  var wmClass = "Boomer"
  var hints = XClassHint(res_name: wmName, res_class: wmClass)

  discard XStoreName(display, win, wmName)
  discard XSetClassHint(display, win, addr(hints))

  var wmDeleteMessage = XInternAtom(
    display, "WM_DELETE_WINDOW",
    0.cint)

  discard XSetWMProtocols(display, win,
                          addr wmDeleteMessage, 1)

  var glc = glXCreateContext(display, vi, nil, GL_TRUE.cint)
  discard glXMakeCurrent(display, win, glc)

  loadExtensions()

  var shaderProgram = newShaderProgram(vertexShader, fragmentShader)

  var screenshot = newScreenshot(display, trackingWindow)
  defer: screenshot.destroy(display)

  let w = screenshot.image.width.float32
  let h = screenshot.image.height.float32
  var
    vao, vbo, ebo: GLuint
    vertices_foo = [
      # Position            Texture coords
      [GLfloat    w,     0, 1.0, 1.0], # Top right
      [GLfloat    w,     h, 1.0, 0.0], # Bottom right
      [GLfloat    0,     h, 0.0, 0.0], # Bottom left
      [GLfloat    0,     0, 0.0, 1.0]  # Top left
    ]
    indices = [GLuint(0), 1, 3,
                      1,  2, 3]

  glGenVertexArrays(1, addr vao)
  glGenBuffers(1, addr vbo)
  glGenBuffers(1, addr ebo)
  defer:
    glDeleteVertexArrays(1, addr vao)
    glDeleteBuffers(1, addr vbo)
    glDeleteBuffers(1, addr ebo)

  glBindVertexArray(vao)

  glBindBuffer(GL_ARRAY_BUFFER, vbo)
  glBufferData(GL_ARRAY_BUFFER, size = GLsizeiptr(sizeof(vertices_foo)),
               addr vertices_foo, GL_STATIC_DRAW)

  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, size = GLsizeiptr(sizeof(indices)),
               addr indices, GL_STATIC_DRAW);

  var stride = GLsizei(vertices_foo[0].len * sizeof(GLfloat))

  glVertexAttribPointer(0, 2, cGL_FLOAT, false, stride, cast[pointer](0))
  glEnableVertexAttribArray(0)

  glVertexAttribPointer(1, 2, cGL_FLOAT, false, stride, cast[pointer](2 * sizeof(GLfloat)))
  glEnableVertexAttribArray(1)

  var texture = 0.GLuint
  glGenTextures(1, addr texture)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, texture)

  glTexImage2D(GL_TEXTURE_2D,
               0,
               GL_RGB.GLint,
               screenshot.image.width,
               screenshot.image.height,
               0,
               # TODO(#13): the texture format is hardcoded
               GL_BGRA,
               GL_UNSIGNED_BYTE,
               screenshot.image.data)
  glGenerateMipmap(GL_TEXTURE_2D)

  glUniform1i(glGetUniformLocation(shaderProgram, "tex".cstring), 0)

  glEnable(GL_TEXTURE_2D)

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)

  var
    quitting = false
    camera = Camera(scale: 1.0)
    mouse: Mouse =
      block:
        let pos = getCursorPosition(display)
        Mouse(curr: pos, prev: pos)
    flashlight = Flashlight(
      isEnabled: false,
      radius: 200.0)
    mirror = false
    warpPending = false
    warpTarget = vec2(0.0'f32, 0.0)

  let dt = 1.0 / rate.float
  var originWindow: Window
  var revertToReturn: cint
  discard XGetInputFocus(display, addr originWindow, addr revertToReturn)
  while not quitting and not gQuit:
    # TODO(#78): Is there a better solution to keep the focus always on the window?
    if not windowed and not live:
      discard XSetInputFocus(display, focusWin, RevertToParent, CurrentTime);

    var wa: XWindowAttributes
    discard XGetWindowAttributes(display, win, addr wa)
    glViewport(0, 0, wa.width, wa.height)

    var xev: XEvent
    while XPending(display) > 0:
      discard XNextEvent(display, addr xev)

      proc scrollUp() =
        if (xev.xkey.state and ControlMask) > 0.uint32 and flashlight.isEnabled:
          flashlight.deltaRadius -= INITIAL_FL_DELTA_RADIUS
        else:
          camera.deltaScale += config.scrollSpeed
          camera.scalePivot = mouse.curr

      proc scrollDown() =
        if (xev.xkey.state and ControlMask) > 0.uint32 and flashlight.isEnabled:
          flashlight.deltaRadius += INITIAL_FL_DELTA_RADIUS
        else:
          camera.deltaScale -= config.scrollSpeed
          camera.scalePivot = mouse.curr

      proc move(idx: int, x: float) =
        case idx
        of 0:
          if (xev.xkey.state and ShiftMask) > 0.uint32:
            camera.velocity[0] = x * config.move_speed * 5.0 / camera.scale
          else:
            camera.velocity[0] = x * config.move_speed / camera.scale
        else:
          if (xev.xkey.state and ShiftMask) > 0.uint32:
            camera.velocity[1] = x * config.move_speed * 5.0 / camera.scale
          else:
            camera.velocity[1] = x * config.move_speed / camera.scale

      case xev.theType
      of Expose:
        discard

      of MotionNotify:
        let motion = vec2(xev.xmotion.x.float32,
                          xev.xmotion.y.float32)

        if warpPending:
          # Events queued before the pointer warp still carry the old
          # position. Drop them until the one at the warp target arrives.
          if motion == warpTarget:
            warpPending = false
          continue

        mouse.curr = motion

        if mouse.drag:
          let delta = world(camera, mouse.prev) - world(camera, mouse.curr)
          camera.position += delta
          # delta is the distance the mouse traveled in a single
          # frame. To turn the velocity into units/second we need to
          # multiple it by FPS.
          camera.velocity = delta * rate.float

          # Infinite drag (like feh): when the pointer reaches a window
          # edge, teleport it to the opposite edge. The delta of this
          # event is already applied, so the panning stays continuous.
          let
            margin = 1.0'f32
            w = wa.width.float32
            h = wa.height.float32
          var target = mouse.curr
          if mouse.curr[0] <= margin: target[0] = w - 2.0'f32 * margin - 1.0'f32
          elif mouse.curr[0] >= w - 1.0'f32 - margin: target[0] = 2.0'f32 * margin
          if mouse.curr[1] <= margin: target[1] = h - 2.0'f32 * margin - 1.0'f32
          elif mouse.curr[1] >= h - 1.0'f32 - margin: target[1] = 2.0'f32 * margin
          if target != mouse.curr:
            discard XWarpPointer(display, None, focusWin, 0, 0, 0, 0,
                                 target[0].cint, target[1].cint)
            discard XFlush(display)
            warpPending = true
            warpTarget = target
            mouse.curr = target

        mouse.prev = mouse.curr

      of ClientMessage:
        if cast[Atom](xev.xclient.data.l[0]) == wmDeleteMessage:
          quitting = true

      of KeyPress:
        var key = XLookupKeysym(cast[PXKeyEvent](xev.addr), 0)
        case key
        of XK_EQUAL, XK_n: scrollUp()
        of XK_MINUS, XK_p: scrollDown()
        of XK_0:
          camera.scale = 1.0
          camera.deltaScale = 0.0
          camera.position = vec2(0.0'f32, 0.0)
          camera.velocity = vec2(0.0'f32, 0.0)
          mirror = false
        of XK_q, XK_Escape:
          quitting = true
        of XK_r:
          if configFile.len > 0 and fileExists(configFile):
            config = loadConfig(configFile)

          when defined(developer):
            if (xev.xkey.state and ControlMask) > 0.uint32:
              echo "------------------------------"
              echo "RELOADING SHADERS"
              try:
                reloadShader(vertexShader)
                reloadShader(fragmentShader)
                let newShaderProgram = newShaderProgram(vertexShader, fragmentShader)
                glDeleteProgram(shaderProgram)
                shaderProgram = newShaderProgram
                echo "Shader program ID: ", shaderProgram
              except GLerror:
                echo "Could not reload the shaders"
              echo "------------------------------"

        of XK_m:
          camera.position[0] += screenshot.image.width.float/camera.scale - 2*(mouse.curr[0]/camera.scale + camera.position[0])
          mirror = not mirror

        of XK_f:
          flashlight.isEnabled = not flashlight.isEnabled
          
        of XK_h:
          move(0,-1.0)
        of XK_j:
          move(1,1.0)
        of XK_k:
          move(1,-1.0)
        of XK_l:
          move(0,1.0)
          
        else:
          discard
           
      of ButtonPress:
        case xev.xbutton.button
        of Button1:
          mouse.prev = mouse.curr
          mouse.drag = true
          camera.velocity = vec2(0.0, 0.0)
        of Button3:
          # live mode has no window to close, always keep a way out by mouse
          if live:
            quitting = true
        of Button4: scrollUp()
        of Button5: scrollDown()
        else:
          discard

      of ButtonRelease:
        case xev.xbutton.button
        of Button1:
          mouse.drag = false
          warpPending = false
        else:
          discard
      else:
        discard

    camera.update(config, dt, mouse, screenshot.image,
                  vec2(wa.width.float32, wa.height.float32))
    flashlight.update(dt)

    if live:
      # picom does the drawing: tell it which part of the screen to show
      camera.scale = max(camera.scale, 1.0'f32)
      let
        winW = wa.width.float32
        winH = wa.height.float32
        centerX = screenshot.image.width.float32 * 0.5'f32 + camera.position[0]
        centerY = screenshot.image.height.float32 * 0.5'f32 + camera.position[1]
        zoomX = max(int(centerX - winW / (2.0'f32 * camera.scale)), 0)
        zoomY = max(int(centerY - winH / (2.0'f32 * camera.scale)), 0)
      setPicomZoom(display, camera.scale, zoomX, zoomY)

      if overlay != 0:
        if flashlight.shadow > 0.01:
          let
            cx = int(zoomX.float32 + mouse.curr[0] / camera.scale)
            cy = int(zoomY.float32 + mouse.curr[1] / camera.scale)
            key = (cx: cx, cy: cy, r: int(flashlight.radius),
                   a: int(flashlight.shadow * 255.0))
          if not overlayMapped:
            discard XMapWindow(display, overlay)
            # the input window must stay on top to keep getting the events
            discard XRaiseWindow(display, focusWin)
            overlayMapped = true
            overlayKey = (cx: -1, cy: -1, r: -1, a: -1)
          if key != overlayKey:
            overlayKey = key
            drawFlashlightOverlay(display, overlay, overlayGc,
                                  attributes.width.cuint, attributes.height.cuint,
                                  cx.float32, cy.float32, flashlight.radius,
                                  flashlight.shadow)
            discard XFlush(display)
        elif overlayMapped:
          discard XUnmapWindow(display, overlay)
          overlayMapped = false
          discard XFlush(display)
      sleep(max(int(1000.0 * dt), 1))
    else:
      screenshot.image.draw(camera, shaderProgram, vao, texture,
                            vec2(wa.width.float32, wa.height.float32),
                            mouse, flashlight, mirror)

      glXSwapBuffers(display, win)
      glFinish()

    when defined(live):
      screenshot.refresh(display, trackingWindow)
      # TODO(#90): don't update the vbo on screenshot refresh
      # I'm pretty sure we can avoid that if we make independent from
      # the size of the window as it was in the beginning. (I simply did
      # not expect this use case back then Kappa)
      var
        w = screenshot.image.width.float32
        h = screenshot.image.height.float32
        vertices = [
          # Position                 Texture coords
          [GLfloat    w,     0, 0.0, 1.0, 1.0], # Top right
          [GLfloat    w,     h, 0.0, 1.0, 0.0], # Bottom right
          [GLfloat    0,     h, 0.0, 0.0, 0.0], # Bottom left
          [GLfloat    0,     0, 0.0, 0.0, 1.0]  # Top left
        ]
        indices = [GLuint(0), 1, 3,
                   1,  2, 3]
      glBindBuffer(GL_ARRAY_BUFFER, vbo)
      glBufferData(GL_ARRAY_BUFFER, size = GLsizeiptr(sizeof(vertices)),
                   addr vertices, GL_STATIC_DRAW)
      glTexImage2D(GL_TEXTURE_2D,
                   0,
                   GL_RGB.GLint,
                   screenshot.image.width,
                   screenshot.image.height,
                   0,
                   # TODO(#13): the texture format is hardcoded
                   GL_BGRA,
                   GL_UNSIGNED_BYTE,
                   screenshot.image.data)
  if live:
    if overlay != 0:
      discard XDestroyWindow(display, overlay)
    discard XUngrabKeyboard(display, CurrentTime)
  else:
    discard XSetInputFocus(display, originWindow, RevertToParent, CurrentTime);
  discard XSync(display, 0)

main()
