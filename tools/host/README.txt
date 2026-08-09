LANMP Server - how to host a game
=================================

1. Double click "Launch Online Multiplayer Server Host". Leave the window
   open while you play.
   (First run, Windows may ask to allow it through the firewall - say yes,
   for Private networks at least.)

2. Everyone else installs the LANMP mod in BeamNG.drive:
   put LANMP.zip in  Documents\BeamNG.drive\<version>\mods\
   then open the LANMP app from the UI apps menu in game.

3. In the LANMP app they press Refresh. Your server shows up by itself if
   they are on the same network. Otherwise they type the IP:port that
   the launcher printed.

4. First time each player picks a username and presses "New account" - the
   server hands back a PIN. That PIN is their password from then on, so
   write it down.

You can host and play on the same PC. The server barely uses anything.

Changing settings
-----------------
Right click "Launch Online Multiplayer Server Host" -> Edit. The top of the
file has the server name, port, max players and starting map.

Playing over the internet
-------------------------
Forward UDP port 4144 from your router to this PC, then give your friends
your public IP (whatismyip.com) instead of the local one. A VPN like
Radmin/Hamachi/Tailscale also works and needs no port forwarding - with
those, the server even shows up in Refresh for anyone on the same VPN.

Troubleshooting
---------------
- Nobody can connect: firewall. Allow lanmp_server.exe, or run
  the launcher as administrator once so it can add the rule.
- "Refresh" finds nothing: you are on different networks (or Wi-Fi guest
  isolation is on). Type the IP manually.
- Wrong version: everyone must use the same LANMP release.
