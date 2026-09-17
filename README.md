# GeeNet — Windows Network Toolkit

**Diagnose · Troubleshoot · Repair**

Made by **George Mwanga**
+255762358050 · GitHub: `github.com/isitgee`
**Version 2.0**

---

## What It Is

GeeNet checks a Windows computer's network the way a good technician does: it looks at the problem, tests the layers in order:

**Physical link → Adapter → IP address → Router → Internet → DNS → Web**

It explains what each result means, fixes what can safely be fixed, and then tests again to see whether the fix actually worked.

GeeNet:

* Works offline
* Installs nothing
* Uses only tools already included with Windows
* Explains diagnostic results instead of simply reporting `FAILED`
* Re-tests after repairs to verify whether they worked

---

## Files

```text
GeeNet/
├── GeeNet.bat          # Launcher — double-click this one
├── GeeNet.ps1          # The toolkit itself (one file, no dependencies)
├── reports/            # Every report and log GeeNet writes
└── tests/              # Self-check harnesses (optional, for development)
```

**Keep `GeeNet.bat` and `GeeNet.ps1` in the same folder.**

---

## Starting GeeNet

### Using the launcher

Double-click:

```text
GeeNet.bat
```

### Command-line options

| Command                    | Description                                |
| -------------------------- | ------------------------------------------ |
| `GeeNet.bat -Beginner`     | Go straight to guided troubleshooting      |
| `GeeNet.bat -Professional` | Go straight to the classic tools           |
| `GeeNet.bat -NoElevate`    | Never offer to restart as Administrator    |
| `GeeNet.bat -Ascii`        | Use plain ASCII markers instead of symbols |
| `GeeNet.bat -SelfTest`     | Check the tool itself and write a report   |
| `GeeNet.bat -Version`      | Print the version                          |
| `GeeNet.bat -Admin`        | Restart with Administrator rights          |
| `GeeNet.bat /?`            | Show short help                            |

You can also run the PowerShell script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File GeeNet.ps1
```

---

## The Main Menu

```text
[1] Beginner - Guided Troubleshooting
[2] Professional - Advanced Tools
[3] Network Information
[4] Generate Network Report
[5] About GeeNet
[6] Restart with Administrator rights
[0] Exit
```

### 1. Beginner — Guided Troubleshooting

You describe the problem in your own words.

GeeNet currently supports:

* **15 problem categories**
* **160 symptoms**
* A guided troubleshooting flow
* Simple questions
* Automatic diagnostic checks
* Explained results
* One-at-a-time repair suggestions

The goal is to make network troubleshooting understandable even for users who don't have advanced networking knowledge.

### 2. Professional — Advanced Tools

Provides direct access to classic networking tools, including:

* Ping
* Traceroute
* DNS lookup
* ARP
* Routing table
* TCP connections
* Wi-Fi information
* Packet loss
* Latency
* MTU checks
* Proxy information
* Continuous ping
* Full diagnostics
* Winsock reset
* TCP/IP reset
* And more

### Other Options

**3 — Network Information**
Displays the complete network configuration in one screen.

**4 — Generate Network Report**
Creates a plain-text network report inside the `reports` folder.

**5 — About GeeNet**
Explains what GeeNet does and what it deliberately does not do.

**6 — Administrator Rights**
Restarts GeeNet with Administrator privileges when required.

---

## How the Diagnosis Works

GeeNet follows the network path in a logical order:

| Step  | What GeeNet Checks                                                   |
| ----- | -------------------------------------------------------------------- |
| **1** | Physical link and adapter — is the cable/Wi-Fi actually connected?   |
| **2** | IP configuration and DHCP — does the computer have a usable address? |
| **3** | Default gateway — is a router address configured?                    |
| **4** | Router reachability — does the router answer?                        |
| **5** | Internet by IP address — does the outside world answer?              |
| **6** | DNS name resolution — can names be turned into addresses?            |
| **7** | Web/HTTPS and applications — does real web traffic work?             |

GeeNet stops when a failure makes the remaining tests meaningless and explains why it stopped.

Press **`[T]`** during a guided session or at the end of Full Diagnostics to see the underlying numbers if a technician needs them.

### Every Check Explains

Each diagnostic result answers five questions:

1. **What was tested and why**
2. **What the result means**
3. **What probably caused it**
4. **What to do next**
5. **Whether GeeNet can fix it itself**

If the problem is outside the computer — for example, with the router, ISP, or physical internet connection — GeeNet says so.

> **You will never see a bare `FAILED`.**

---

## Repairs

GeeNet uses risk-tiered repairs and explains them before execution.

### 🟢 Low Risk

Examples include:

* Clear DNS cache
* Renew the IP address
* Restart/reconnect the network adapter
* Restart the Wi-Fi service
* Clear ARP cache
* Register DNS

### 🟡 Moderate Risk

Examples include:

* Reset Winsock
* Reset TCP/IP
* Switch to a public DNS server

### 🔴 High Risk

Examples include:

* Windows network reset
* Forgetting a saved Wi-Fi profile

High-risk operations are clearly labelled and require additional confirmation.

### Before Every Repair

GeeNet explains:

* What the repair does
* Why it might help
* What you may notice
* How to undo it

After performing the repair, GeeNet:

1. Checks the actual result
2. Re-tests the affected diagnostic checks
3. Reports whether the repair helped

If a repair doesn't work, GeeNet says so plainly.

---

## Administrator Rights

GeeNet detects whether it is running with Administrator privileges.

**Diagnostics do not require Administrator rights.**

Repairs that modify system settings request approval when necessary. You can also use:

```text
[6] Restart with Administrator rights
```

---

## What GeeNet Will Never Do

GeeNet is designed to be transparent and safe.

* It **never restarts or shuts down your computer** automatically.
* If a repair requires a restart, it tells you and leaves the decision to you.
* It **never changes anything without explaining it and asking first**.
* It **never claims a repair worked without checking and re-testing**.
* It **never claims certainty**. It uses language such as *"most likely"* and *"this suggests"*.
* It **never sends your data anywhere**.
* It **does not require internet access to start**.
* It **cannot repair your router or physical internet line** and says so instead of guessing.

---

## Reports and Logs

GeeNet generates plain-text reports that can be opened in Notepad.

| File                                       | Purpose                                 |
| ------------------------------------------ | --------------------------------------- |
| `reports\GeeNet_Guided_Report_<date>.txt`  | Complete guided troubleshooting session |
| `reports\GeeNet_Network_Report_<date>.txt` | Network configuration and diagnosis     |
| `reports\GeeNet_SelfTest_<date>.txt`       | GeeNet's self-test results              |
| `%TEMP%\GeeNet\GeeNet_Session_<date>.log`  | Timestamped session log                 |

The report path is always displayed on screen.

Reports contain network configuration and diagnostic results only.

**They do not contain:**

* Passwords
* Browsing history
* Personal files

---

## Requirements

GeeNet is designed for:

* Windows 10
* Windows 11
* Older/slower Windows machines
* Windows PowerShell 5.1 (built in)
* PowerShell 7+

### No Additional Software Required

GeeNet requires:

* No installation
* No extra downloads
* No Python
* No Node.js
* No third-party modules
* Windows built-in networking tools

The interface is designed for a standard **78-column console window**.

---

## Tests Folder

The `tests` folder contains optional development and validation tools.

```text
tests\
├── Test-GeeNetLibrary.ps1
├── Test-GeeNetFlows.ps1
├── Test-GeeNetProfessional.ps1
├── Inspect-GeeNetScenario.ps1
└── Check-GeeNetData.py
```

### Test Files

| Test                                    | Purpose                                       |
| --------------------------------------- | --------------------------------------------- |
| `Test-GeeNetLibrary.ps1 -Mode healthy`  | Tests every symptom against mock data         |
| `Test-GeeNetFlows.ps1`                  | Tests the guided flow, menu, and reports      |
| `Test-GeeNetProfessional.ps1`           | Tests every direct tool                       |
| `Inspect-GeeNetScenario.ps1 -Id INT-09` | Inspects one symptom and its full explanation |
| `Check-GeeNetData.py`                   | Checks static data consistency                |

The tests use simulated Windows networking data, so they can run on any machine with PowerShell.

### Built-in Self Test

The normal way to check GeeNet is:

```text
GeeNet.bat -SelfTest
```

The self-test performs:

**225 checks**

including:

* Data integrity
* 21 simulated network situations

---

## Troubleshooting GeeNet

### `"running scripts is disabled"`

Use:

```text
GeeNet.bat
```

The launcher passes the required execution policy.

Alternatively:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File GeeNet.ps1
```

### Nothing happens when double-clicking

Right-click `GeeNet.bat` and choose:

**Run as administrator**

### No colours or strange symbols

Use:

```text
GeeNet.bat -Ascii
```

### Self-test fails

Keep the generated report:

```text
reports\GeeNet_SelfTest_*
```

and include it when reporting the problem.

---

## Project Summary

**GeeNet** is a lightweight Windows network troubleshooting toolkit designed to bridge the gap between simple "run this command" utilities and a proper technician-style diagnostic workflow.

It doesn't just run commands.

It tries to answer:

> **What is wrong, why does it matter, what can I do about it, and did the fix actually work?**

---

### Author

**George Mwanga**
Computer Science Student · Tanzania

GitHub: `github.com/isitgee`

**GeeNet v2.0**
