on run {daemon_file, agent_file, user}

  set sh1 to "echo " & quoted form of daemon_file & " > /Library/LaunchDaemons/com.carriez.NormanRemoteDesktop_service.plist && chown root:wheel /Library/LaunchDaemons/com.carriez.NormanRemoteDesktop_service.plist;"

  set sh2 to "if [ -n " & quoted form of agent_file & " ]; then echo " & quoted form of agent_file & " > /Library/LaunchAgents/com.carriez.NormanRemoteDesktop_server.plist && chown root:wheel /Library/LaunchAgents/com.carriez.NormanRemoteDesktop_server.plist; else uid=$(id -u " & quoted form of user & " 2>/dev/null || true); if [ -n \"$uid\" ]; then launchctl bootout gui/$uid /Library/LaunchAgents/com.carriez.NormanRemoteDesktop_server.plist 2>/dev/null || launchctl bootout user/$uid /Library/LaunchAgents/com.carriez.NormanRemoteDesktop_server.plist 2>/dev/null || true; fi; rm -f /Library/LaunchAgents/com.carriez.NormanRemoteDesktop_server.plist; fi;"

  set sh3 to "cp -rf /Users/" & user & "/Library/Preferences/com.carriez.RustDesk/RustDesk.toml /var/root/Library/Preferences/com.carriez.RustDesk/;"

  set sh4 to "cp -rf /Users/" & user & "/Library/Preferences/com.carriez.RustDesk/RustDesk2.toml /var/root/Library/Preferences/com.carriez.RustDesk/;"

  set sh5 to "launchctl load -w /Library/LaunchDaemons/com.carriez.NormanRemoteDesktop_service.plist;"

  set sh to sh1 & sh2 & sh3 & sh4 & sh5

  do shell script sh with prompt "NormanRemoteDesktop wants to install daemon and agent" with administrator privileges
end run
