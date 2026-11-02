# Only the gnome-session family lists unsaved work where another process can read it; Plasma and XFCE let a logind power-off through with no save prompt

**Date:** 2026-11-01 · **Method:** reading upstream source at the tags below; no guest was run.

| Project | Tag or revision |
|---|---|
| plasma-workspace, powerdevil, kwin, xdg-desktop-portal-kde | v6.8.2 (Logout.qml at v6.7.0, see finding 1) |
| xfce4-session | xfce4-session-4.20.4 |
| xfce4-power-manager | xfce4-power-manager-4.20.1 |
| gnome-session | 50.1, 51.0, and main 0cfee22 |
| gnome-settings-daemon | 50.1 |
| systemd | v255, v257, v259 |
| cinnamon-session | HEAD 7bedb01 |
| mate-session-manager | HEAD 57a9178 |
| xdg-desktop-portal-gtk | HEAD 5409af7 |

## Summary of findings

1. **The ACPI power key, with upstream defaults.**
   - **Plasma 6.8:** PowerDevil holds logind's `block` lock on `handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch` (powerdevil `daemon/powerdevilpolicyagent.cpp:864-868`), so logind ignores the key. PowerDevil takes it as the `Key_PowerOff` shortcut (`daemon/actions/bundled/handlebuttonevents.cpp:60-73, 225-228`); the desktop default is `PromptLogoutDialog` (`daemon/powerdevilsettingsdefaults.cpp:126-129`), which calls `SessionManagement::requestLogoutPrompt` (`suspendsession.cpp:121-125`).
     - While the screen saver is active, that shows nothing (plasma-workspace `libkworkspace/sessionmanagement.cpp:144-163`).
     - Otherwise it calls `org.kde.LogoutPrompt.promptAll` with `ShutdownTypeDefault` (`logout-greeter/greeter.cpp:173-181`). In Logout.qml the countdown runs only when `!showAllOptions`, which `ShutdownTypeDefault` sets (v6.7.0 `lookandfeel/org.kde.breeze/contents/logout/Logout.qml:46-60, 86-91`). Logout.qml is not at that path in v6.8.2; where it moved was not found.
     - So the key reaches a save-prompting logout only when someone at the screen picks Shut Down.
   - **XFCE 4.20:** xfce4-power-manager holds logind's `block` lock on `handle-power-key` (and the suspend, hibernate and lid keys), since `logind-handle-power-key` defaults to FALSE (`common/xfpm-config.h:91-92`; `src/xfpm-manager.c:490-560`). `power-button-action` defaults to `XFPM_DO_NOTHING` (`xfpm-config.h:78-79`), and Xubuntu's shipped `xfce4-power-manager.xml` (xubuntu-default-settings, master) does not override it. "Ask" calls `org.xfce.Session.Manager.Logout(TRUE,TRUE)` (`xfpm-manager.c:192-209`); "Shutdown" calls logind `PowerOff` with no save (`:161-190`).
   - **Either desktop, with its power manager not running:** logind applies `HandlePowerKey=poweroff` (systemd v259 `src/login/logind.conf.in:28`), with no save.
   - **GNOME 50 in a VM:** gnome-settings-daemon ignores `power-button-action` unless it is `nothing` and calls logind `PowerOffWithFlags(0)` from the user's session (`plugins/media-keys/gsd-media-keys-manager.c:2142-2150`, `logind_power_action` at `:2002`; schema `org.gnome.settings-daemon.plugins.power.gschema.xml.in:39-43`). On systemd 255 logind lets the caller's own uid through its `block` lock (v255 `src/login/logind-dbus.c:1913`, `manager_is_inhibited(..., ignore_uid=true, uid)`); from 257 it refuses, and gnome-settings-daemon drops the reply. Whether hostnamed reports chassis `vm` on an Apple Virtualization guest was not checked.

2. **A logind `PowerOff` from another process.** Nothing in Plasma or XFCE holds a `shutdown` lock, `block` or `delay`, or listens for `PrepareForShutdown`:
   - plasma-workspace v6.8.2 declares the signal only in a generated header (`libkworkspace/login1_manager_interface.h:396`) and calls `Inhibit` from no other file;
   - kwin v6.8.2's only lock is a `sleep` `delay` (`src/core/session_logind.cpp:217-218`);
   - powerdevil's only lock is the `handle-*` one above;
   - xfce4-session 4.20.4 and xfce4-power-manager 4.20.1 have neither.

   So logind powers off at once and no app is asked to save, whoever the caller is. A `delay` lock could not host save prompts either: `InhibitDelayMaxSec` defaults to 5 s (systemd v259 `man/logind.conf.xml:179-185`).

3. **Where Plasma and XFCE record unsaved work, none of it reaches logind or a documented API.**
   - xdg-desktop-portal-kde keeps apps' logout inhibits in an internal map (`src/inhibit.cpp:184-189`), exposed only through the undocumented `org.kde.SessionState.queryCanEndSession` (`inhibit.cpp:46-73, 242-283`). No caller was found in plasma-workspace (v6.8.2 or master) or kwin v6.8.2.
   - xfce4-session's inhibit registry only greys out Shut Down and Restart in its own dialog (`xfce4-session/xfsm-shutdown.c:466-529`).
   - On XFCE the portal config routes Inhibit to xdg-desktop-portal-gtk (`xfce4-session/xfce-portals.conf`), which forwards to `org.gnome.SessionManager` (`src/inhibit.c:569-621`), which XFCE does not run.
   - Whether an individual KDE or XFCE app takes its own logind shutdown lock was not checked.

4. **The gnome-session family.** `org.gnome.SessionManager.GetInhibitors` lists the session's inhibitors, each with its flags and app id.
   - gnome-session 50.1 mirrors a logout inhibit into logind as a `shutdown` `block` lock, `who` the user name and `why` "user session inhibited" (`gnome-session/gsm-systemd.c:666-714`); 51.0 takes it as `block-weak`, as `shutdown:sleep` when suspend is inhibited too (`gsm-systemd.c:538-557`). The process that takes it owns `org.gnome.SessionManager`: at gnome-session main 0cfee22, `gnome-session/meson.build` builds `gsm-systemd.c` into `gnome-session-service`, whose `service-main.c:172-173` owns the name. The 2026-10-28 note's finding 2 saw that lock's pid on `gnome-session-s` (GNOME 50) and `gnome-session-b` (GNOME 46).
   - cinnamon-session mirrors only suspend-flagged inhibits (`csm_systemd_add_inhibitor` returns early without SUSPEND, `cinnamon-session/csm-systemd.c:722-755`), and mate-session-manager never calls logind `Inhibit`. Both own `org.gnome.SessionManager`. Whether MATE answers `GetInhibitors` as its XML declares was not checked.
   - An app that relies on XSMP, or inhibits only from GTK's `query-end` at logout, is in no list another process can read.

5. **The desktops' own shutdown calls.** None both protects unsaved work unattended and tells its caller the outcome.
   - KDE `org.kde.Shutdown.logoutAndShutdown`/`logoutAndReboot` (D-Bus-activated `plasma-shutdown`, `startkde/plasma-shutdown/org.kde.Shutdown.xml`, `CMakeLists.txt:26`) return nothing and emit no signal; on cancel the process quits (`shutdown.cpp:40-70, 126-130`). Its flow runs ksmserver's XSMP save phase, where a prompting client has no timeout (`ksmserver/logout.cpp:86-140, 202-252`), then KWin's `closeWaylandWindows`, which after 2 minutes logs out anyway (kwin v6.8.2 `src/sm.cpp:367-449`), then `PowerOff(true)` (`libkworkspace/sessionmanagementbackend.cpp:176-186`).
   - XFCE `org.xfce.Session.Manager.Shutdown(allow_save)`/`Restart` replies before its save phase (`xfsm-manager.c:2378-2461`), shows no dialog (`:1268-1300`), asks only XSMP clients (`:1113-1129`; `SAVE_TIMEOUT` 60 s for non-interacting clients, `xfsm-manager.h:41`), and does not consult its own inhibit registry. A cancel emits `ShutdownCancelled` (`:1209-1245`).

## What this means for Kernova

A logind power-off is equivalent to the desktop's own logout only where that logout consults nothing but an inhibitor list another process can read: the gnome-session family's `GetInhibitors`. Plasma's logout also runs XSMP and closes every window, and XFCE's runs XSMP; no list reflects either.
