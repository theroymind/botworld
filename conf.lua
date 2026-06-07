function love.conf(t)
  t.identity = "botworld"
  t.version = "11.4"

  t.window.title = "Botworld — drone swarm benchmark"
  t.window.width = 1280
  t.window.height = 720
  t.window.resizable = true
  t.window.vsync = 0 -- uncapped so the benchmark measures real throughput

  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
