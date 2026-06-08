function love.conf(t)
  t.identity = "botworld"
  t.version = "11.4"

  t.window.title = "Botworld"
  t.window.width = 1280
  t.window.height = 720
  t.window.resizable = true
  t.window.vsync = 1 -- cap to the display refresh; this is an idle game, not a throughput benchmark

  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
