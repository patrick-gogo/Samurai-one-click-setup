# Launches the Samurai Patrick Command Center dashboard (production build) in the
# background at Windows startup. Rebuilds from the current source on every run so
# it always serves whatever is on `main`, then serves the fresh build.

$ProjectDir = "C:\Users\john\Desktop\samurai-patrick-command-center"

Set-Location $ProjectDir
npm run build
npm run start
