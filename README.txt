================================================================================
 GeeNet - Windows Network Toolkit
 Diagnose | Troubleshoot | Repair
 Made by George Mwanga   +255762358050   github.com/isitgee
 Version 2.0
================================================================================

WHAT IT IS
----------
GeeNet checks a Windows computer's network the way a good technician does: it
looks at the problem, tests the layers in order (physical link -> adapter ->
IP address -> router -> internet -> names -> web), says what each result means,
fixes what can safely be fixed, and then tests again to see whether the fix
actually worked.

It works offline, installs nothing, and uses only tools Windows already has.


FILES
-----
  GeeNet.bat        launcher - double-click this one
  GeeNet.ps1        the toolkit itself (one file, no dependencies)
  reports\          every report and log GeeNet writes
  tests\            self-check harnesses (optional, for development)

Keep GeeNet.bat and GeeNet.ps1 in the same folder.


STARTING IT
-----------
  Double-click GeeNet.bat                 open the menu
  GeeNet.bat -Beginner                    go straight to guided troubleshooting
  GeeNet.bat -Professional                go straight to the classic tools
  GeeNet.bat -NoElevate                   never offer to restart as Administrator
  GeeNet.bat -Ascii                       plain ASCII markers instead of symbols
  GeeNet.bat -SelfTest                    check the tool itself and write a report
  GeeNet.bat -Version                     print the version
  GeeNet.bat -Admin                       restart with Administrator rights
  GeeNet.bat /?                           short help

You can also run the script directly:
  powershell -NoProfile -ExecutionPolicy Bypass -File GeeNet.ps1


THE MAIN MENU
-------------
  [1] Beginner - Guided Troubleshooting
      You describe the problem in your own words (15 categories, 160 symptoms).
      GeeNet asks at most a couple of simple questions, runs its own checks,
      explains every result, and offers repairs one at a time.

  [2] Professional - Advanced Tools
      The classic tools, directly: ping, traceroute, DNS lookup, ARP, routing
      table, TCP connections, Wi-Fi info, packet loss, latency, MTU, proxy,
      continuous ping, full diagnostics, Winsock/TCP-IP resets and more.

  [3] Network Information         the full configuration in one screen
  [4] Generate Network Report     plain-text report in the reports folder
  [5] About GeeNet                what it does, and what it never does
  [6] Restart with Administrator rights (only shown when not already elevated)
  [0] Exit


HOW THE DIAGNOSIS WORKS
-----------------------
  1. Physical link and adapter      - is the cable/Wi-Fi actually connected?
  2. IP configuration and DHCP      - does the computer have a usable address?
  3. Default gateway                - is a router address configured?
  4. Router reachability            - does the router answer?
  5. Internet by IP address          - does the outside world answer at all?
  6. DNS name resolution            - can names be turned into addresses?
  7. Web (HTTPS) and applications   - does real web traffic work?

GeeNet stops as soon as a failure makes the remaining tests meaningless, and it
says why it stopped. Press [T] in the guided session (or at the end of Full
Diagnostics) for the numbers behind the diagnosis if a technician asks for them.
Every check answers five questions:

  - what was tested and why
  - what the result means
  - what probably caused it
  - what to do next
  - whether GeeNet can fix it itself (or whether only the router, ISP or user can)

You will never see a bare "FAILED".


REPAIRS
-------
Repairs are risk-tiered and always explained before they run:

  Low       clear the DNS cache, renew the address, restart/reconnect the
            adapter, restart the Wi-Fi service, clear ARP cache, register DNS
  Moderate  reset Winsock, reset TCP/IP, switch to a public DNS server
  High      network reset, forget a saved Wi-Fi profile (last resort, clearly
            labelled, and it asks twice)

Before each repair you see what it does, why it may help, what you will notice,
and how to undo it. GeeNet then runs it, checks the real result, and re-tests
the affected checks - and it will say plainly when a repair did not help.

Administrator rights are detected. Diagnostics never need them; repairs that
change system settings ask for approval, or use menu option [6].


WHAT GEENET WILL NEVER DO
-------------------------
  - It never restarts or shuts down your computer. If a repair needs a restart,
    it tells you so and leaves the decision to you.
  - It never changes anything without explaining it and asking you first.
  - It never claims a repair worked without checking the result and re-testing.
  - It never claims certainty - it says "most likely" and "this suggests".
  - It never sends your data anywhere, and it needs no internet to start.
  - It cannot repair your router or your internet line, and it says so instead
    of guessing.


REPORTS AND LOGS
----------------
  reports\GeeNet_Guided_Report_<date>.txt      the guided session, end to end
  reports\GeeNet_Network_Report_<date>.txt     network configuration + diagnosis
  reports\GeeNet_SelfTest_<date>.txt           the tool checking itself
  %TEMP%\GeeNet\GeeNet_Session_<date>.log      timestamped session log

All plain text, all readable in Notepad, all written to disk - the path is always
printed on screen. Reports contain network configuration and test results only:
no passwords, no browsing history, no personal files.


REQUIREMENTS
------------
  Windows 10 or Windows 11 (older and slower machines included)
  Windows PowerShell 5.1 (built in) or PowerShell 7+
  No installation, no extra downloads, no Python/Node/third-party modules
  Text is laid out for a standard console window (78 columns)


THE TESTS FOLDER (optional)
---------------------------
  tests\Test-GeeNetLibrary.ps1 -Mode healthy   every symptom against mock data
  tests\Test-GeeNetFlows.ps1                   the guided flow, menu, reports
  tests\Test-GeeNetProfessional.ps1            every direct tool, one by one
  tests\Inspect-GeeNetScenario.ps1 -Id INT-09  one symptom, full explanation
  tests\Check-GeeNetData.py                    static data consistency (Python)

They run with simulated Windows data, so they work on any machine with
PowerShell. The built-in self test is what you normally use:

  GeeNet.bat -SelfTest    (225 checks: data integrity + 21 simulated situations)


TROUBLESHOOTING THE TOOL
------------------------
  "running scripts is disabled"  -> use GeeNet.bat (it passes -ExecutionPolicy
                                    Bypass), or run the exact command line above
  Nothing happens on double-click-> right-click GeeNet.bat, Run as administrator
  No colours / strange symbols   -> GeeNet.bat -Ascii
  Self test fails                -> keep the report from reports\GeeNet_SelfTest_*
                                    and include it in the bug report

================================================================================
