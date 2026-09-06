# All notable changes to the **FedUpDate** (`fedupdate`) project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.36] - 2026-09-06

### Fixed

- **Opening The Application Asked For Administrator Rights (`core/AntiTamperWatchdog.ps1`, `gui/Server.ps1`)**:
  - Somebody installs this, opens it, and is asked to hand over administrator rights before touching anything. Nothing had been requested. The previous release taught the audit to ask for the elevation it needs to read the scheduled tasks, which is right when a person has pressed Run Audit and is waiting for an answer. But an audit is also taken as part of a scan, and asking what was already known still started a scan when nothing was known yet, which is every first launch. So opening the interface ran a scan, which ran an audit, which asked for administrator rights.
  - Elevation is asked for only where a person asked for the audit: the button, the command, and the text interface's watchdog screen. Everything else reads what it can and reports the rest as unread.
  - Asking what is already known no longer starts anything. Nothing is known on a fresh installation, and that is a true and perfectly good answer.

- **Opening The Application Contacted GitHub (`gui/Server.ps1`, `gui/app.js`)**:
  - Which version this is, is a question about this machine. Whether a newer one exists is a question about somewhere else, and going to ask it means reaching out over the network on somebody's behalf. The interface did that on every launch, so an application nobody had yet touched had already contacted a server about them.
  - The installed version is answered from the installation. The check for a newer one happens when it is asked for. Until then the interface says the version has not been checked, rather than implying it is current, because not having looked is not the same as being up to date.

---

## [1.0.35] - 2026-09-06

### Fixed

- **The Audit Examined Three Of The Eleven Settings It Was Auditing (`core/AntiTamperWatchdog.ps1`)**:
  - The shield changes eleven things. The audit looked at three of them, plus its own boot guard, and reported the machine in its desired state on the strength of that. The four remaining registry values and the three scheduled tasks were not checked, not reported as unchecked, and not mentioned. Somebody pressing Run Audit was told their shield was healthy after a quarter of it had been examined.
  - Every setting the shield manages is now read, and the list the audit reads is the same list the enforcement acts on, so the two cannot come to describe different machines.

- **The Audit Asked For Nothing And Therefore Saw Nothing (`core/AntiTamperWatchdog.ps1`)**:
  - Reading the scheduled tasks needs elevation. The audit never asked for it, so from an ordinary session it could not see them, and rather than saying so it simply left them out. There was no prompt because there was no intention to look.
  - It asks now, the same way checking for Windows updates asks. The elevated run is a separate process that exits, so its answer is written down where the session that asked for it can pick it up. Declining is an answer: the audit still runs and reports those settings as unread rather than as correct.

- **The Audit Reported Nothing It Had Found (`gui/app.js`, `gui/index.html`, `core/AntiTamperWatchdog.ps1`)**:
  - It gathered a name, an expected value, an actual value and a verdict for each setting, and the interface kept one boolean out of all of it and discarded the rest. It also wrote nothing to the log, so an audit left no trace and could not be shown to have happened at all.
  - Each setting is listed with what it should be, what it is, and whether it has drifted, could not be read, or is as it was set. Every one of them is written to the log as well, with a closing line saying how many drifted and how many could not be read.

- **An Enforcement That Changed Eight Settings Reported That Nothing Needed Doing (`core/AntiTamperWatchdog.ps1`, `core/RollbackEngine.ps1`)**:
  - The summary counted what had been recorded rather than what had been applied. Since a setting's original is written down only once, that count is zero on every run after the first, so a run that had just set six registry values, reconfigured a service and disabled a task announced that everything was already as it should be, four seconds after the lines saying otherwise.
  - It counts what it actually put back.

---

## [1.0.34] - 2026-09-06

### Fixed

- **The Progress Drawer Stayed Open Over The Settings Control (`gui/app.js`)**:
  - The drawer that reports what is running never closed after enforcing the shield, and it sits over the settings control, so there was no way to reach settings afterwards short of closing the application. Nothing in the drawer decided when it had finished; it was put away by whatever happened to run next, which for years had been the scan that followed every action. The previous release removed that scan, correctly, since nobody had asked for it, and took the only thing that ever closed the drawer with it.
  - A drawer reporting finished work now puts itself away, after long enough to be read. Nothing else has to remember to do it, and a task that is still running keeps it open regardless of how many other things have finished in the meantime.

---

## [1.0.33] - 2026-09-06

### Fixed

- **The Application Checked The Machine Without Being Asked (`gui/app.js`)**:
  - Opening the desktop interface started a full audit of the machine, and enforcing the shield started another one afterwards. Neither was asked for. A person could open the window, press one button and close it again, and the log would afterwards show a Windows Update scan, a WinGet scan and a Store check, indistinguishable from ones they had actually requested. An application whose whole argument is that the machine belongs to the person using it does not help itself by going through it uninvited.
  - Opening the window shows what is already known, with its age, and leaves the machine alone. Scan System is there for when an answer is wanted. Enforcing the shield refreshes whether the shield has drifted and nothing else, because enforcing it says nothing about what updates are pending. Every check that remains follows something a person did: asking for an elevated check, installing updates, updating packages, or rolling back.

- **The Boot Guard Ran Every Minute Instead Of Every Fifteen (`core/AntiTamperWatchdog.ps1`)**:
  - The guard registered itself on every enforcement, and one of the triggers it wrote started a minute after registration. So each enforcement scheduled another one a minute later, which enforced, which registered again, which scheduled another. It ran every sixty seconds for the life of the machine while reporting on every line that it runs every fifteen minutes.
  - A guard already registered and enabled is left alone rather than written again, and the trigger that covers the current session starts one interval out rather than one minute out.

- **An Enforcement That Changed Things Reported That Nothing Had Changed (`core/RollbackEngine.ps1`)**:
  - A run that set six registry values and reconfigured a service finished by saying nothing had changed in it. What there was none of was anything new worth writing down, the originals being already on record. Plenty had changed. It now says what it means.

- **An Enforcement Left Seconds Of Silence In The Log (`core/AntiTamperWatchdog.ps1`)**:
  - Settings already as they should be are not recorded, which is right, but they had also stopped being mentioned, so an enforcement passed several seconds working through scheduled tasks without a word about any of it. Each enforcement now says how many settings it looked at and how many needed putting back.

- **The Text Interface Wrote Nothing To The Log (`tui/TuiEngine.ps1`)**:
  - Somebody could open it, run an update from it and close it again, and the log would carry the update with no account of where it had been asked for. Read afterwards, the work appeared to have happened by itself. Opening it, each choice made in it, and closing it are now recorded, by name rather than by keystroke.

---

## [1.0.32] - 2026-09-06

### Fixed

- **The Interface Would Not Finish Starting Because It Could Not Say Which Version It Was (`core/Version.ps1`, `install.ps1`, `core/Engine.psm1`)**:
  - The version was read out of the changelog. The previous release stopped shipping the changelog, correctly, since it is written for the people making this application rather than the people running it. Nothing else knew the version, so an installation had none, and the interface sat on its opening screen until a timeout let it through. Every new installation did this.
  - An installation is stamped with its version while it is being installed, by the installer, which has the source in front of it and therefore knows. After that the application carries its own version and needs nothing else on disk to answer for it. Run from a copy of the source instead, the changelog is right there and is still the authority.

- **Putting A Setting Back Created Another Restore Point Every Time (`core/RollbackEngine.ps1`)**:
  - Windows turns some of these settings back on by itself, and putting them back is the entire point of the shield. Each of those rounds was written down as though it had discovered something, so a shield doing its job produced a growing list of restore points that all restore to the same place. Four of the five points on a fresh installation were the same scheduled task, disabled again and again.
  - What a setting was is recorded the first time this application touches it. After that the answer cannot change, so putting a setting back where it belongs is enforcement and nothing is recorded for it. The setting is still put back, and the original written down first is still what an uninstall uses.

### Changed

- **Installing Copies The Application, Not The Repository It Is Kept In (`install.ps1`)**:
  - The source of this application is a working tree, and a working tree holds a great deal that never runs: artwork the readme uses, screenshots for the project page, icons rendered at every size any platform might one day ask for, a licence, a changelog, a contributing guide, a security policy, workflow definitions. All of it was being copied onto people's machines. Several megabytes of pictures and developer paperwork sat in their program folder with nothing to explain what any of it was for.
  - What is installed is now named rather than what is left out, so nothing added to the repository later can arrive on somebody's machine by default. The entry points, the engine, the two text interfaces, the desktop interface, and the seven pieces of artwork the running application actually reads. An installation is thirty two files rather than seventy odd, and under a megabyte rather than eight.
  - An upgrade removes what earlier versions left behind, so a machine carrying the clutter is cleared by its next update. The data directory is not in any of the lists, which is a firmer promise than skipping it: nothing in the copy can reach configuration, logs, the ledger or the rollback snapshots at all.

---

## [1.0.31] - 2026-09-06

### Fixed

- **Uninstalling Did Not Remove The Application (`install.ps1`)**:
  - The removal of the installed files was handed to a second process told to wait for the uninstalling process to finish first. Run the way anybody runs it, by typing the command into their own terminal, the uninstalling process is that terminal, and a terminal does not finish because somebody typed a command into it. So the second process sat waiting for up to two minutes on something that was never going to happen, while the uninstall announced that the files were removed and returned to the prompt with every one of them still there. Running it again found the installation again and announced the same thing again, indefinitely.
  - The files are removed there and then, by the uninstall itself. A script is read into memory rather than held open, so an uninstall is not standing on what it is deleting and there was never a reason to defer it. Anything genuinely still in use is handed to a retry that waits for nothing, and a removal with nothing left over starts no second process at all.
  - What is reported is what was found afterwards rather than what was asked for. The line claiming the files were removed was printed on the strength of having requested a removal, which is how it came to be printed eight times over an application that was still installed.

- **The Installer Put The Repository On The Machine Instead Of The Application (`install.ps1`)**:
  - Everything in the source was copied to the installation directory except the data folder. That meant a licence, a changelog, a contributing guide, a security policy, a readme, the workflow definitions, the files telling git what to ignore, and the development history itself, all landing in somebody's program folder. None of it is the application. It is the paperwork of making the application, and it left people looking at a folder full of things with no explanation for why they were on their computer.
  - What is installed is the application: the interfaces, the engine, the assets, the entry points and the installer itself, which the uninstall and the in place update both need. An upgrade also removes what an earlier version left behind, so a machine that already has the clutter is cleared by the next update rather than keeping it forever.

---

## [1.0.30] - 2026-09-06

### Added

- **The Machine Is Written Down At Installation, Before Anything Is Changed (`install.ps1`, `core/RollbackEngine.ps1`, `core/AntiTamperWatchdog.ps1`, `core/Engine.psm1`)**:
  - Everything this application offers to undo rests on knowing how the machine was before it arrived. That was being learned during enforcement, which is the one moment it cannot be learned, because the values read then are the ones the enforcement has just written. On a machine already holding these settings, whether from an earlier installation or from somebody setting them by hand, the enforced values were recorded as that machine's own originals. An uninstall then put those values back and reported the machine restored, having restored nothing.
  - Installing now reads every setting this application is able to change, as it finds them, and writes them down before a single one is touched. It changes nothing while doing so. It is also the first thing that writes the log, so an installation is no longer something that happens to a machine without a record of it.
  - It happens once. A later installation keeps the baseline already taken, because the first answer is the true one and any later reading is a reading of this application's own work.
  - The settings the enforcement changes and the settings the baseline records now come from one list, so the record cannot describe one set of things while the change is made to another.

### Fixed

- **A Setting That Could Not Be Read Was Recorded As Absent (`core/RollbackEngine.ps1`)**:
  - Scheduled tasks under the Windows Update folders are invisible to an ordinary session. Read from one, they come back as not found, which is not what is there. Recorded that way, an uninstall would act on a state nobody had ever observed.
  - A setting that could not be read is recorded as unread, and told apart from one genuinely absent. A restore leaves an unread setting alone rather than moving it somewhere unobserved, and the count reported after a baseline says how many were read and how many were not.

---

## [1.0.29] - 2026-09-05

### Fixed

- **A Machine Already Holding These Settings Had Nothing Recorded About It (`core/RollbackEngine.ps1`)**:
  - The previous release stopped writing down a setting that was found already holding the value being applied, on the grounds that nothing had been changed. That is true of the change and false of the setting. A machine can already be sitting at these values, from an earlier installation of this application or from the person having set them by hand, and on such a machine the first run found nothing to change and therefore recorded nothing at all. There was then no record of what the machine had looked like, and an uninstall offering to put everything back had nothing to put back.
  - What a setting was is now written down the first time this installation touches it, whether or not it needs changing. After that it is not written down again, because the answer does not change and the record exists. A setting that genuinely moves later is still recorded as the change it is.
  - Whether a setting has been written down before is now read once for each run rather than once per setting, so a run costs a single pass over a record that holds one entry per setting.

---

## [1.0.28] - 2026-09-05

### Fixed

- **Uninstalling Replayed Every Record Instead Of Putting Each Setting Back Once (`core/RollbackEngine.ps1`)**:
  - This application changes ten things: six registry values, one service and three scheduled tasks. Undoing them is ten operations. Choosing to undo them during an uninstall instead worked through every record ever written, one at a time, which on a machine that had been running the shield for a while meant tens of thousands of writes that all finish at the same place. An uninstall that should take seconds sat there long enough to look broken, and there was nothing on screen to say what it was doing or how much was left.
  - Undoing everything now works out what each setting was before this application first touched it, and puts it back once. The earliest record of a setting is the one that holds its true original, because every later record only saw what had already been applied, so collapsing to anything newer would restore the enforced value and leave the machine changed by its own uninstall.

- **The Record Of Changes Grew Without Limit (`core/RollbackEngine.ps1`)**:
  - What a setting was before this application first moved it is a fact that is settled the moment it is first written down. It does not change afterwards, and there is exactly one of it per setting. The shield nevertheless checks itself on a timer and re-applies the same settings whether or not anything has moved, and every one of those checks was written down in full, as though each had discovered the original state again. The record grew by ten entries every quarter of an hour for as long as the application stayed installed, all describing the same ten settings, and a machine left running for a few weeks accumulated tens of megabytes of it.
  - A setting found already holding the value being asked for has not been changed, so nothing is recorded for it. The same now applies to a service already set the way it is being asked for and to a scheduled task already in the state being asked for. The original is written down the first time this application moves a setting, and never again. A setting that genuinely moves later is still recorded, because that is a change with something to undo.

### Changed

- **The Uninstall Prompt Says The Application Is Going (`install.ps1`)**:
  - It opened by asking what should happen to the update settings, and never said the removal itself was already settled, so the plain uninstall looked like it was missing from its own list of options. The first answer was that uninstall, described in terms of Windows defaults rather than in terms of removing anything.
  - It now says the application is being removed before it asks anything else, and the first answer is the ordinary uninstall in plain words. That answer is the default, so it can be taken with the Enter key rather than studied for. Keeping settings deliberately still has to be asked for, and an unattended run still has to state its outcome, because there is nobody there to have meant anything.

---

## [1.0.27] - 2026-09-05

### Added

- **The Desktop Interface Offers The Same Reading The Text One Does (`core/OSUpdateEngine.ps1`, `tui/TuiEngine.ps1`, `gui/app.js`, `gui/styles.css`)**:
  - Each pending update carried the address of Microsoft's article for it, and only the text interface showed it. The desktop interface listed the same updates with the same article numbers and offered no way to reach any of them, so which interface was open decided whether reading before installing was possible at all.
  - The article number in the update list is now the way to the article. An update with nothing published is left as it was, with no address invented for it, and a driver update still says who documents it instead. The article opens in the reader's own browser rather than replacing the interface with a web page.
  - The address is worked out once, on the update itself, and every interface reads that. It was being worked out where it was displayed, which is how two interfaces come to disagree about the same update, and this application has spent enough releases on exactly that.

---

## [1.0.26] - 2026-09-05

### Fixed

- **Reopening The Window After An Update Failed Before It Started (`install.ps1`)**:
  - The step that reopens the desktop window after an update built its path from a variable belonging to a different part of the installer. Out where it ran, that variable holds nothing, so the line failed on its first instruction, before anything could be launched. It also sat outside the handling written to report exactly this, so the failure passed without a word. The window closed to be updated and stayed closed, which is the behaviour that was supposed to have been fixed.
  - The paths are built from the install root that exists where the step runs, and building them happens inside the handling that reports a failure, so a path that cannot be built is said out loud rather than ending the run in silence.

- **Reopening After An Update Brought Back The Page, Not The Application (`install.ps1`, `fedupdate-gui.vbs`)**:
  - The application is the compiled window. It draws its own title bar, which is the point of it, and it starts the server it needs by itself. The script sitting beside it starts only that server, and a server with no window of its own is reached through a browser, which frames the page in the operating system's chrome and leaves two title bars stacked on each other. It is a different thing wearing the application's face.
  - Reopening after an update reached for that script first. So an update ended by presenting the page inside a browser frame rather than the application, which is not what the shortcuts open and not what anybody asked for. It now opens the same file the shortcuts open, and nothing else.
  - The launcher itself was named for the interface and did not open it either, reaching straight past the application for the server. It opens the application when it is there. Starting the server remains the fallback for a machine where the window could not be built, but it is the fallback rather than the first choice.

---

## [1.0.25] - 2026-09-05

### Changed

- **Updating From The Interface Says What Is About To Happen (`gui/app.js`)**:
  - Updating closes this window part way through, because the file it runs from is replaced while it runs, and it opens again once the new version is built. None of that was said beforehand. The window simply disappeared, which reads as a crash rather than as the update working, and there was no way to tell the two apart while waiting to find out.
  - What is going to happen is now said before it happens, and agreed to. Declining changes nothing.
  - The message shown when the update finished asked for a restart. It was written to a window that had already been closed to make the update possible, so it could not be read, and a restart is no longer needed in any case. The only time that message can now be reached is when there was nothing to install, and it says so.

---

## [1.0.24] - 2026-09-05

### Fixed

- **Updating From Inside The Desktop Window Left No Desktop Window (`gui/bin/build.ps1`, `install.ps1`)**:
  - The desktop interface is compiled on the machine it runs on, and the file it runs from has to be writable for a new one to be written into it. So updating from within the window closes that window, deliberately, part way through. Nothing opened it again. An update started from Settings ended with the interface gone, no message, and no indication that this was intended rather than a crash, since the message saying the update had finished was written to a window that had already been closed to make the update possible.
  - What is closed to do the work is opened again once the work is done, through the launcher that shows no terminal, exactly as a shortcut would. An update run from a terminal with nothing open still opens nothing, because putting back a window that was never there is not the same act.

- **Closing The Window Left Its Server Running (`gui/Server.ps1`, `gui/src/Program.cs`)**:
  - The interface runs a small local server for its own use and stops it on the way out. A window that is killed rather than closed never reaches that point, and updating kills the window, so every update from inside the interface left a server behind with nothing to serve. They accumulated quietly, one per update, invisible in any interface and outliving every session that created them.
  - The server is now told which window it belongs to and stops when that window is gone, however it went. A server started on its own, without a window, is left alone.

---

## [1.0.23] - 2026-09-04

### Added

- **Every Pending Windows Update Is Offered Its Own Reading Before It Is Installed (`core/OSUpdateEngine.ps1`, `core/Engine.psm1`, `tui/TuiEngine.ps1`)**:
  - A pending update was a title, an article number and a size, which is enough to know that something is about to change and nothing about what. The text interface now prints the address of Microsoft's article for each pending update, so the decision to install can be made after reading rather than before.
  - The address is taken from the update itself, since the Update Agent records where Microsoft documents each one. Only when an update carries no address of its own is the article reached through its article number. Building an address from a number is a guess, and it is used only where there is nothing better.
  - An update with nothing to read is told apart from an update whose reading was not found. A driver update carries no Microsoft article because the hardware maker documents it, and that is what is said. Anything else without an article is described in the article of whatever update carries it, and that is said instead. Neither is presented as a missing page.
  - The address never names a language. Microsoft serves these articles in the reader's own language when none is named, so a reader in Sweden reaches the Swedish article and a reader anywhere else reaches theirs. Where Microsoft's own records name a language, which is whichever one the record happened to be written in, it is removed. A hardware maker's address is passed through untouched, since nothing here knows how their site is arranged.

- **An Update Names What It Carries Inside It (`core/OSUpdateEngine.ps1`, `tui/TuiEngine.ps1`)**:
  - A cumulative update is not one thing. It carries components that are never shipped separately and have no article of their own, the servicing stack update being the usual case, and those were installed unannounced because only the outermost update was ever listed. The components an update carries are now named beside it, so what is about to be installed is stated rather than implied by a single line.

---

## [1.0.22] - 2026-09-04

### Fixed

- **Navigation Icons Were Drawn At Noticeably Different Sizes (`gui/index.html`)**:
  - Every icon in the navigation rail is given an identical box, so they were expected to match. They did not. An icon looks the size its drawing is, not the size its box is, and the drawings occupied anywhere between seventy and one hundred percent of the space allotted to them. The Windows and Store marks reached the edges of their frames with no margin at all, while the dashboard and log marks sat well inside theirs, leaving the largest rendering forty three percent bigger than the smallest in a row where all ten are meant to read as one set.
  - Two causes sat behind it. The Windows and Store marks were drawn on a twenty four unit grid while the other eight use twenty, and nothing required one grid over the other. More significantly, those two were drawn edge to edge, whereas the rest carry the margin their icon set is designed with.
  - Each icon's frame is now padded so that all ten carry the same share of their box. No artwork was altered and no colour was touched, only the frame the existing drawing sits in. The difference in rendered size between the largest and the smallest is now nothing.

---

## [1.0.21] - 2026-09-04

### Fixed

- **A Windows Update Search That Never Finished Was Reported As A Result (`core/OSUpdateEngine.ps1`)**:
  - The search was given thirty seconds. Reading Windows' local update catalogue takes moments, but asking Windows Update itself is a network call that routinely takes longer than that, so the online search was frequently being cut off rather than answered. When it was cut off, whatever was already known locally was returned in its place and reported as the finding, so a search that measured nothing came back as a confident count. A count of zero produced that way is indistinguishable from a system with nothing outstanding.
  - This mattered more than it reads, because the check that decides what an installation achieved is that same online search. Cut off, it would have returned nothing outstanding and every update would have been reported as installed, which is the false success the check exists to prevent.
  - A search now gets the time the kind of search needs, and one that does not finish is reported as not having finished. Nothing is presented as measured, an earlier answer that did finish is kept rather than being overwritten by an empty one, and an installation whose check did not complete is reported as unconfirmed rather than as done.

---

## [1.0.20] - 2026-09-04

### Fixed

- **An Update That Had Installed Was Reported As Still Pending, And Offered Again Forever (`core/OSUpdateEngine.ps1`)**:
  - After installing, the run checked what was still pending by reading Windows' local update catalogue. An installation does not rewrite that catalogue, so it went on listing the update that had just been installed. The run therefore reported nothing installed and one still pending, the interfaces kept offering that update, and installing it again produced exactly the same outcome. Windows' own update screen listed nothing, because the update was in fact installed. The two accounts could never converge, because only one of them was being asked anything new.
  - The check that runs after an installation now asks Windows Update rather than reading the catalogue, so it reflects what is actually still outstanding. A routine scan still reads the catalogue, which is what keeps it quick, but a routine scan is not being asked to prove that something installed.
  - When the Update Agent says an update succeeded and Windows still offers it afterwards, both facts are now reported. Which of the two is right is not something this can settle, so neither is quietly discarded.

- **Updates Without A KB Article Were Counted As KBs (`gui/app.js`, `tui/TuiEngine.ps1`)**:
  - Driver updates and optional updates generally carry no KB article, and the pending count was labelled in KBs regardless. A single driver update with no article number was presented as one KB pending, naming it after an identifier it does not have and that nothing else on the system would show for it. The table went further and filled the empty column with an invented label rather than leaving it empty.
  - The count is now given in updates, and an update with no KB article is shown as having none.

---

## [1.0.19] - 2026-09-04

### Fixed

- **Finishing An Update Run Left The Windows Update Card Saying Nothing Had Been Checked (`core/OSUpdateEngine.ps1`)**:
  - A run that installed Windows updates ended by discarding what it knew was pending, on the grounds that installing had just made it untrue. Nothing replaced it. The check that follows a run is not elevated, the shield refuses it, and with the previous answer thrown away there was nothing left to fall back on, so the card went back to reporting that Windows updates had not been checked at all. The two engines beside it reported their real state, because neither of them needs elevation to look.
  - The run now asks once more before it finishes, while it still holds the elevation it needed to install, and records that answer. A completed run leaves the state it produced rather than leaving nothing, so the card reports what is actually pending afterwards instead of admitting ignorance the moment the work is done.

- **Updates That Had Installed Were Reported As Not Installed (`core/OSUpdateEngine.ps1`)**:
  - Each update's outcome was taken from the number the Update Agent reports against it. That number is not evidence. A driver update that Windows had installed came back marked as never started, so the run named it as not installed while Windows' own update screen had already stopped listing it. Trusting that number replaced one false report with another in the opposite direction.
  - What installed is now settled by looking. The run checks again once the installation is finished, and an update that is no longer pending installed, whatever the Agent said about it. One that is still pending did not, and is named along with what the Agent claimed, since the two disagreeing is worth seeing. If the re-check itself cannot run, nothing is presented as confirmed either way.

### Changed

- **Update Outcomes Are Reported In Words (`core/OSUpdateEngine.ps1`, `core/Engine.psm1`)**:
  - An update that did not install was logged with the Update Agent's numeric outcome, which tells nobody anything. The distinction matters: an update Windows declined to start is a different situation from one it tried and could not complete, and only one of those is worth trying again. Each outcome is now named, and an unrecognised one still reports its number rather than being hidden.

---

## [1.0.18] - 2026-09-04

### Fixed

- **Windows Updates Were Reported As Installed By A Run That Installed None Of Them (`core/OSUpdateEngine.ps1`, `core/Engine.psm1`)**:
  - An update run listed the pending Windows updates, said it had downloaded and installed them, and finished reporting success. Nothing had been installed. The updates were still pending afterwards, still listed here and still listed in Windows' own update screen, including after a restart. Driver updates showed this most plainly, because they are the ones that tend to sit there unchanged, but it applied to every Windows update the run claimed to have handled.
  - The installation ignored the list it had just produced. Instead of installing the updates that were found, it started again and asked the Update Agent a second time for whatever was pending, then installed the answer to that second question. The two questions were not the same one: the scan reads the local update catalogue, while the installation left its search settings at their defaults and went to the network. The two disagreed, so the list a person was looking at was not the list being acted on, and on this machine the second search returned nothing at all.
  - Finding nothing to install was treated as a completed run rather than a failure. Asked for two updates and offered none of them back, it recorded no successes, no failures and no error, so nothing anywhere said the run had achieved nothing.
  - Installing needs elevation, so an unelevated run hands the work to a second process. That process exits, and its exit code says only that it ran. The result was taken to mean that every requested update had been installed. A run that installed nothing exited cleanly, and so was reported as having installed everything.
  - Every update carries its own outcome, and none of them was read. The number reported as installed was the number attempted, so updates Windows had refused were counted alongside the ones that went on.
  - Updates that carry a licence were never granted one. An unaccepted licence stops that update downloading, and driver updates are the ones that usually carry it, so those could not have installed even had everything else been right.
  - The installation now acts on the updates the scan found, matched individually, using the same search the scan used. Licences are accepted before download. Each update's own result decides whether it counts as installed, and anything that did not install is named, with driver updates marked as such. An update that was asked for and not offered back is named too. Being offered none of them is an error, not a completed run. The elevated process records what it actually did and the unelevated one reads that record, so no result is ever inferred from an exit code.

---

## [1.0.17] - 2026-09-04

### Fixed

- **Only One Button In The Window Could Answer The Windows Update Question (`gui/app.js`)**:
  - Scanning from the dashboard ran every engine, was refused on Windows updates because the shield keeps the update service disabled and the window does not run elevated, and stopped there reporting that the updates had not been checked. Elevation, the one thing that could have answered, was offered only from the Windows Updates tab. Pressing Scan System therefore produced a result that could never improve no matter how many times it was pressed, and the way out existed on a different screen with nothing on the dashboard to say so.
  - A scan that a person started and that could not answer now offers the elevated check wherever it was started from. The offer is made in one place, in the scan itself, rather than written into each button, so no entry point can be a dead end and none of them decides this for itself. Declining leaves everything untouched, as before.

---

## [1.0.16] - 2026-09-04

### Fixed

- **The Elevated Windows Update Check Threw Its Own Answer Away (`core/OSUpdateEngine.ps1`, `core/Engine.psm1`, `core/Logger.ps1`, `fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/app.js`)**:
  - Checking for Windows updates is refused while the shield has the update service disabled, unless the session is elevated, and no interface runs elevated. The way out was to accept an elevation prompt, which started a second process, checked properly, printed to a hidden console and exited. Only its exit code came back. The result itself went nowhere. The interface then ran another check in its own unelevated session, was refused exactly as before, and reported that Windows updates had not been checked. Accepting the prompt changed nothing that could be seen, so the check appeared to do nothing at all, every time, no matter how often it was accepted.
  - A check that runs is now written down, with the time it was taken. A session that is refused reads what the last successful check found instead of reporting nothing, and says when it was taken and that it came from an elevated check. The elevated prompt therefore produces a visible answer, which is the whole reason it is offered.
  - A count is never presented as current when it is not. Every interface that shows a carried over result shows its age beside it, and installing updates discards the record, because what was pending before an install cannot still be pending after it.
  - The distinction between a check that found nothing and a check that never ran is preserved. With nothing recorded, a refused check still reports that it was not checked rather than inventing a zero.

- **The Command Line And Text Interface Reported Nothing When An Answer Existed (`fedupdate.ps1`, `tui/TuiEngine.ps1`)**:
  - Both read only whether the current session had been refused, so both printed that Windows updates were not checked even when a successful elevated check had already answered the question minutes earlier. They now report the count and when it was taken, and fall back to not checked only when nothing has ever been recorded.

---

## [1.0.15] - 2026-08-28

### Fixed

- **The Windows Updates Tab Reported A Result From A Check It Never Made (`gui/app.js`)**:
  - With the shield on, checking for Windows updates is refused unless the session is elevated, and the desktop window is not elevated. The refusal came back with no updates attached, and the table on the Windows Updates tab read that empty list as an answer and printed that Windows is fully up to date. The dashboard card beside it read the same scan correctly and said the check had not been made. One scan, one set of data, two tabs disagreeing about it, and the one that sounded confident was the one that was wrong.
  - The table now reports a refused check as a refused check, names the reason, and offers the elevated check that can answer the question. A check that ran and genuinely found nothing still reports the system up to date, and a check that found updates still lists them.
  - Scan OS Updates on that tab repeated the refusal every time it was pressed, since nothing about pressing it again could lift the condition that caused the refusal. When the last check was refused it now asks for elevation instead, which is the only thing that can produce an answer. The shield is restored straight afterwards.

- **The Collapsed Navigation Rail Named Nothing (`gui/app.js`, `gui/styles.css`)**:
  - Collapsed, the rail is nine glyphs and no text, and hovering one produced nothing. Each destination carried a browser tooltip, which waits about a second, is drawn by Windows rather than by this application, and cannot be placed against the rail. In practice the rail was unlabelled at exactly the width where the labels are gone.
  - Hovering or tabbing to a glyph now names the destination immediately, in the application's own surface, border and type, placed to the right of the rail. The names are kept on the buttons for screen readers, so nothing was traded away to get this.

---

## [1.0.14] - 2026-08-28

### Fixed

- **The Terminal Banner Spelled The Name Wrong (`tui/TuiEngine.ps1`, `README.md`)**:
  - The lettering that opens the text interface was damaged. A backtick belongs in the middle of the artwork, and a backtick is also how PowerShell escapes the next character, so the one in the source was read as an instruction rather than as ink and took the character after it with it. The row carrying the descender of the p was missing outright. What was left ran the U and the p together into a single shape that most people read as a W, so the application introduced itself under a name it does not have.
  - The lettering is restored in full, the backtick is escaped so it survives as a character, and the descender row is back. The name reads as FedUpDate.

### Changed

- **The Line Under The Banner Starts At The Left Edge (`tui/TuiEngine.ps1`)**:
  - It was indented by four spaces for no reason, so it sat adrift of the lettering above it and the rule below it. It now begins where every other line on the screen begins.

---

## [1.0.13] - 2026-08-28

### Changed

- **The Terminal Banner Names the Application (`tui/TuiEngine.ps1`)**:
  - The line under the banner read as a version and a tagline with nothing to attach them to. It now reads FedUpDate, the version, then the tagline.

---

## [1.0.12] - 2026-08-26

### Fixed

- **An Update Run Skipped Windows Updates Whenever the Shield Was On (`core/OSUpdateEngine.ps1`)**:
  - Installing begins by checking what is pending. With the shield on, that check is refused unless the session is elevated, and the refusal came back as an empty list, which the installer read as nothing to do. It then reported the run complete. The elevation it needed existed a few lines further down and was never reached, because the decision not to bother had already been taken on the strength of a check that never ran. Whenever the shield was doing its job, which is the normal state, no Windows update was ever installed by a run started from the command line, the text interface or the desktop interface.
  - A refused check is no longer mistaken for an empty one. When the check is refused and the session is not elevated, the run asks for elevation, so that checking and installing happen together in one elevated pass. A check that ran and genuinely found nothing still reports nothing pending and asks for nothing. Declining the prompt is reported as exactly that, neither as an error nor as nothing pending, and a simulated run says it could not check rather than pretending it did.

---

## [1.0.11] - 2026-08-26

### Fixed

- **The Text Interface Never Launched From the Command Line (`tui/TuiEngine.ps1`)**:
  - The text interface is loaded by reading its file straight into the command line script. That file ended with a cmdlet that may only run inside a module, and the command line script treats every error as fatal, so loading the interface failed at its last line and the interface itself was never started. This has been so since the first public release. Every function in it was fine; only the way it announced itself was wrong.
  - The offending line is gone. The file is never imported as a module, so it had nothing to export in the first place.

---

## [1.0.10] - 2026-08-26

### Changed

- **The Cleanup Notice Shows What It Is About (`gui/app.js`)**:
  - Every notification carries a glyph that depicts its subject, a shield for the watchdog, a package for updates, a hazard for a restart the system is waiting on, and the card's type says how much it matters. The cleanup notice was the exception: its glyph said only that it was informational, which is the one thing the card's colour already said. It now carries a broom, which says what it is about and, being calm, reinforces that nothing needs doing.

---

## [1.0.9] - 2026-08-26

### Fixed

- **Pressing a Notification Dragged the Window (`gui/app.js`)**:
  - The notification panel sits inside the title bar, and the title bar treats a press anywhere on it as the start of moving the window. Only buttons and inputs were exempt, so pressing on the text of a notification moved the whole window instead, and a double click maximised it.
  - The panel is now treated as content rather than as furniture. Everything else in the title bar still moves the window as before.

- **Expanding the Navigation Jumped Rather Than Moved (`gui/styles.css`)**:
  - Only the width of the rail was animated. The alignment of each row, its spacing and the appearance of each label all changed in the same instant the rail began to move, and none of those can be animated, so the glyphs jumped to their new place and the labels appeared at full size inside a rail that had not widened yet.
  - The glyph is now placed by an offset that travels with the rail instead of by an alignment that flips, and the labels fade and unfurl as it opens.

### Changed

- **Text That Is Only Text Can Be Selected (`gui/styles.css`)**:
  - Nothing in the interface could be selected or copied, including the log. What the engine reported and what a notification says are read back, pasted into an issue and quoted, and copying them from a screenshot is absurd.
  - The streamed log lines, the live line in the dock and the text of a notification can now be selected. The toolbars, tabs, navigation and buttons still cannot, so a press on the window furniture still moves the window.

- **The Version Left the Title Bar (`gui/index.html`)**:
  - It is still reported in the corner panel on the settings page, which is where it is looked for. The markup is commented rather than removed.

---

## [1.0.8] - 2026-08-25

### Fixed

- **Asking for Help Produced a Parameter Binding Error (`fedupdate.ps1`)**:
  - The command name was checked against a fixed list before the script ran, so anything outside it was refused by PowerShell rather than answered. Asking for help in any of the usual ways produced an error about validation sets, and a single dash form was read as the name of a parameter that does not exist.
  - Help now answers to every spelling people reach for, and the version does too. There is no single letter form for version, because PowerShell resolves that to its own verbose switch and claiming it here would make both ambiguous.
  - A command that is genuinely unrecognised is answered by the application: it says which one it did not recognise, lists what it accepts, and exits with a failure code rather than printing an internal binding error.

---

## [1.0.7] - 2026-08-25

### Fixed

- **The Shield Was Applied Once at Startup and Lost for the Rest of the Session (`core/AntiTamperWatchdog.ps1`)**:
  - Windows repairs its own update components while the machine is running, not only across a restart. The guard was registered to run at startup and nothing more, so it applied the chosen settings once, Windows undid them within minutes, and nothing looked again until the next restart. The settings were therefore absent for almost the whole time the machine was in use, and enforcing them by hand only lasted until Windows next intervened.
  - The guard now re-applies the chosen state every fifteen minutes for as long as the machine is running, so tampering is reversed rather than merely noticed at the next boot. The interval is a parameter.
  - It carries two triggers rather than one. A startup trigger only begins repeating once it has fired, which means a machine already running would have waited until its next restart before the guard ever ran again. The second trigger begins immediately and repeats for the life of the session.

---

## [1.0.6] - 2026-08-25

### Fixed

- **The Dashboard Stopped Rendering When a Scan Reported It Was Refused (`gui/app.js`)**:
  - The notification list read whether the update check had been refused, but never took that value from the scan it was given, so every render raised an error. The error was caught by the polling that waits for a scan to finish, which then kept waiting rather than stopping, so the interface only appeared once that polling gave up on its own after roughly a minute and a half.
  - The desktop interface was the only one affected. The command line, the text interface and the engine were reading the value correctly throughout.

---

## [1.0.5] - 2026-08-25

### Fixed

- **A Refused Update Check Was Reported as Zero (`core/OSUpdateEngine.ps1`, `core/Engine.psm1`, `fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/app.js`)**:
  - The anti-tamper shield disables the Windows Update service on purpose. With it disabled, asking Windows what updates are pending fails outright unless the session is elevated, and that failure was caught and turned into an empty list. A refusal and a genuinely clean system therefore produced the same answer, and the interfaces printed a confident zero for a number nobody had been allowed to measure.
  - A refused check is now recorded as refused. All three interfaces say the check did not run and why, rather than showing a count.
  - Each of them also offers the way through: checking can be done once with elevation, and the shield is restored immediately afterwards by the same code that borrows it. Declining changes nothing.

- **Tool Output Bypassed the Log (`core/OSUpdateEngine.ps1`, `core/StoreEngine.ps1`, `gui/bin/build.ps1`)**:
  - The Defender updater, the Store source refresh and the compiler were each started in a way that hands them the console directly, so their banners and version listings appeared raw in the middle of a run, in none of the formatting used around them and in none of the log files.
  - Their output is captured now. The one useful line Defender produces, whether signatures were actually needed, is reported through the log like everything else. The compiler is asked not to print its banner at all.

- **One Log Tag Was Wider Than the Rest (`core/Logger.ps1`)**:
  - Every level is padded so the message column lines up. WHATIF was a character wider than the other five, so any line carrying it sat out of column.

---

## [1.0.4] - 2026-08-24

### Fixed

- **The Boot Guard Reported Success Without Checking (`core/AntiTamperWatchdog.ps1`)**:
  - Registering the on-boot guard piped its result away and did not stop on an error, so a refusal was discarded and the guard was reported as registered either way. The message said the machine was defended at startup whether or not anything had been created, which is the one answer that stops anybody looking further.
  - Registration now stops on an error and asks for the task back afterwards. If it is not there, it says so plainly rather than claiming otherwise.

- **A Guard That Could Not Be Seen Was Reported as Missing (`core/AntiTamperWatchdog.ps1`)**:
  - The guard runs as the system account and its definition is readable only by the system and by administrators, so an ordinary session cannot see it at all. The audit read that silence as absence and reported the guard as not installed, which was wrong in the common case and alarming in exactly the situation where nothing was actually wrong.
  - An ordinary session is now told the guard cannot be seen without elevation, rather than told it is missing. A guard that is genuinely absent still counts as drift, but only from a session able to tell the difference, so a standard user is never marked as permanently drifted for a state they cannot observe.

---

## [1.0.3] - 2026-08-24

### Fixed

- **Engine Glyphs Were Too Faint to Read in the Light Theme (`gui/styles.css`)**:
  - The three engine marks measured between 2.50 and 2.97 against the well they sit in, under the 3.0 a graphical object needs to stay legible. They now measure 3.57 to 3.82. Contrast follows lightness rather than saturation, so only the lightness was lowered and each mark keeps its own hue.

- **Two Colours Were Specified Outside What a Screen Can Show (`gui/styles.css`)**:
  - The information and purple badge text in the dark theme were written beyond the sRGB gamut, so the browser clipped them and what appeared was never quite what the token said. Both are now inside the gamut and still read at 6.49 and 5.48.

- **The Warning Colour Was Nearly Grey and the Danger Colour Shouted (`gui/styles.css`)**:
  - In the light theme the amber sat at a third of the saturation of every colour beside it, so it read as washed out rather than as a warning, while the red was half again more saturated than anything else and drew the eye whether or not it mattered. The set now spans a third of the range it did.
  - Red also drifted between themes, at one hue in the dark and another in the light for no reason. Both themes now use the same red.
  - The danger badge was the only one in the light theme using its own coloured text while the other four shared a neutral, which made it stand out twice over. All five now match.

### Changed

- **A Card's Colour Says Which Engine It Is, Not How It Is Doing (`gui/styles.css`, `gui/index.html`, `gui/app.js`)**:
  - The three status badges used blue, purple and amber to say the same thing, that updates are waiting, which read as three unrelated conditions rather than one. They now share a single colour for waiting and green for nothing to do.
  - Identity moved to the glyph, where `--sys-engine-os`, `--sys-engine-winget` and `--sys-engine-store` name what a colour is for rather than which hue it happens to be. Windows Update is blue, WinGet is amber and the Store is green, matching what the marks have always meant. The WinGet glyph had drifted to purple.

### Added

- **Contrast Checks (`audit/audit-contrast.js`)**:
  - Converts the tokens to what a screen renders, composites translucent fills over the surface beneath them, and holds text to 4.5 and graphical objects to 3.0. It validates its own colour conversion against known colours first, because an unchecked conversion produces numbers that look authoritative and are not. It reports which pair failed and exits accordingly, so a palette this closely tuned cannot drift back unnoticed.

---

## [1.0.2] - 2026-08-23

### Fixed

- **WinGet Exclusions Set in the Interface Were Never Honoured (`gui/app.js`, `gui/Server.ps1`)**:
  - The settings page wrote the exclusion list as `winget.excluded_packages` and read it back from the same place, so it always looked saved. The upgrade reads `exclusions.wingetPackageIds`, which is a different setting the page never wrote. A package excluded from upgrades was therefore shown as excluded and upgraded anyway. The default list is Microsoft Edge and OneDrive, so the two entries most likely to be excluded were the two least likely to be respected.
  - The page now writes and reads the names the engine uses, for the exclusion list and for the theme. The theme happened to survive only because the server carried a fallback for the mismatch, which is no longer needed and has gone.

### Changed

- **The Branding Splash Is Sized for the Window It Sits In (`gui/src/Program.cs`)**:
  - The mark was drawn into a 92 unit box in a window more than eight hundred units tall, with the wordmark and progress bar to match, so the whole composition read as small rather than deliberate. It is drawn at 168 now with the text and bar scaled with it. The source is 512 square, so it stays within its own resolution even on a display scaled to 250 percent.

---

## [1.0.1] - 2026-08-23

### Changed

- **Prompts Belong to the Application (`gui/index.html`, `gui/app.js`)**:
  - Confirming a restart, a shutdown or a rollback, and being told that a filter matched nothing, used the browser's own dialogs. The host draws those as a plain system window titled with the local address the interface is served from, which follows neither the theme nor the wording of anything around it and puts an implementation detail in front of the user.
  - Those six are now asked and answered inside the application, using the same card the uninstall dialog uses. They can be dismissed with the keyboard or by clicking away from the card, and dismissing means declining, so nothing acts on a question that was closed rather than answered.

### Fixed

- **A Pinned Taskbar Shortcut Outlived the Application (`install.ps1`)**:
  - Uninstall removed the Start menu and desktop shortcuts and left any the user had pinned themselves, so a pinned taskbar icon stayed behind pointing at a directory that no longer existed. Pinned shortcuts are now removed with the rest. Explorer keeps its own view of the taskbar, so an icon can remain on screen until it next reads that, but nothing is left for it to run.
  - A Windows 11 Start menu pin is held in a database with no supported way to edit it. That one is left alone deliberately rather than poked at, and it is written down here rather than left as a surprise.

---

## [1.0.0] - 2026-08-23

First stable release. The command line verbs and their switches, the keys in
`config.json`, the installer's switches, the state ledger format and the update
channel contract are now settled, and none of them change again without a major
version. Everything below this entry is the development history that got here.

### Added

- **Update Channels (`core/Config.ps1`, `core/Version.ps1`, `gui/index.html`, `gui/app.js`)**:
  - An installation follows either the stable channel or the beta channel, set from Settings and stored as `updateChannel`. Stable is offered published releases and installs from the main branch. Beta is offered prereleases as well and installs from the development branch.
  - The channel decides both halves, and that is the point of it. An update detected from one place and installed from another reports itself as available again the moment it finishes, which is a loop no amount of updating clears. A channel that has published nothing yet is reported as exactly that rather than as a network failure, and anything unrecognised in the configuration resolves to stable, because offering somebody a prerelease they did not ask for is the worse of the two mistakes.
  - Release notes follow the channel too, so a stable installation is not shown notes for versions it will never be offered.

- **Distance From the Installed Version (`core/Version.ps1`, `gui/Server.ps1`, `gui/app.js`)**:
  - The version panel reports how many commits the channel's branch has gained since the installed release, which a version number on its own cannot say. It is read once and held for the life of the interface, because the unauthenticated interface to the release data allows sixty requests an hour for the whole machine.

- **The Window Records Its Own Startup (`gui/src/Program.cs`)**:
  - Window startup is written into the same rolling log as the engine, so a splash waiting on an audit can be told apart from one that is stuck without sitting and watching it.

### Fixed

- **Saving Preferences Replaced the Entire Configuration (`core/Config.ps1`, `gui/Server.ps1`)**:
  - The interface posts the settings it knows about, and the endpoint wrote that object to disk whole. Everything it did not mention, which was the reboot policy, the watchdog rules, the scheduler and the exclusions, was deleted by the act of saving a theme. Changes are now merged onto what is already stored, so a caller that knows about two settings cannot remove the rest.

- **The Splash Left Before the First Audit, Then Stayed Until Its Timeout (`gui/app.js`, `gui/src/Program.cs`)**:
  - The interface announced that it was ready from inside an animation frame. A view that is not being rendered is not given animation frames, so once the interface was correctly hidden behind the splash the announcement was never sent, and the splash sat until its own ceiling instead of until the work finished.
  - The announcement is sent directly now. Waiting for a paint was pointless in any case, because what the host waits to hear is that the first audit has finished, not that a frame has been drawn.

- **An Unreachable Update Check Reported Being Up To Date (`gui/app.js`)**:
  - Not having read a release is not the same as having read one and matching it. The panel now says which of the two happened.

---

## [0.5.9-beta] - 2026-08-23

### Fixed

- **The Branding Splash Was Painted Over the Moment the Page First Drew (`gui/src/Program.cs`)**:
  - The interface control hosts its own window handle, so it draws over the window's own content whatever the layout order says. It was left visible from the moment the window opened, which meant the first paint of the page covered the splash no matter when the splash had been told to leave. Holding the splash for longer, as the previous release did, changed nothing that could actually be seen.
  - The interface is now hidden until the splash is released. The branding has the window to itself for as long as the first audit runs, and the dashboard appears only once that audit has finished rather than while it is still going. The control is hidden rather than collapsed, because a collapsed control is given no size and never creates the window handle the browser needs in order to start.

---

## [0.5.8-beta] - 2026-08-23

### Fixed

- **Branding Splash Left the Screen Before the First Audit (`gui/src/Program.cs`, `gui/app.js`)**:
  - The interface posts a message when its startup work is finished, and the host never handled that message. The splash was released instead by a timer started before the page had even been navigated to, so it went as soon as that elapsed and the window appeared while the first audit was still running.
  - A second signal fired from the window's load event, which arrives once the page's resources are in and long before startup has finished, so it released the splash earlier still.
  - The audit was started without being waited on, so startup reported itself complete before the audit had begun.
  - The splash is now held for as long as the first audit runs. A minimum keeps it from flashing past when that audit returns immediately, and a ceiling releases the window if the report never arrives at all.

- **Navigation Glyphs Sat Off Centre While Collapsed (`gui/styles.css`)**:
  - The rail carried rules for its expanded state only. Collapsed, each row kept the inline padding that places a glyph beside its label, and with no label present that padding is a fixed offset from the left edge rather than a centre, so every glyph sat to one side of the rail's centre line. Collapsed rows are now centred and that padding is dropped.

### Changed

- **Every Brand Mark Ships, and Each Surface Uses the One Built for It (`README.md`, `gui/index.html`, `gui/Server.ps1`, `gui/src/Program.cs`, `gui/bin/build.ps1`, `install.ps1`, `assets/`)**:
  - The repository now carries the complete set of marks under `assets/`, sorted by where they belong: `app/` for the splash and title bar, `desktop/` for the Windows icon and the iconset and hicolor sets, `readme/` for documentation, `web/` for the favicon, touch icon and progressive web app marks, and `master.png` as the source the rest is rendered from.
  - One 1024 pixel image stood in for the readme mark, the splash, the browser tab icon, the touch icon and the 22 pixel mark in the title bar. Each of those now has an asset built for it. The tab icon carries only the three sizes a tab draws at, the title bar mark is picked by pixel density so it is sharp on a scaled display without decoding a megapixel to fill 22 of them, and the window, taskbar and shortcut icon is one file holding every size Windows asks for.

- **The Navigation Toggle Shows Its State Instead of Naming It (`gui/index.html`, `gui/app.js`)**:
  - The toggle spelled out Collapse beside its glyph whenever the rail was open. The glyph already says what the control does, so the word is gone and the state is carried where it is useful, on the control itself and in its tooltip.

---

## [0.5.7-beta] - 2026-08-23

### Fixed

- **Routine Installer Cleanup Reported as a Required Restart (`core/RebootEngine.ps1`)**:
  - Windows keeps a list of files an installer has asked to have removed or replaced during the next restart. Ordinary use writes to that list constantly, because a browser or a security product that updates itself leaves its old temporary folder behind for the system to clear on the way up. Any entry at all was taken as proof that the system was waiting on a restart, so the notification centre asked for one, then asked again a few hours after the machine came back, because by then the next update had queued its own cleanup.
  - The list is now read as the pairs of source and destination it actually holds. An entry with no destination is a deletion, which is how an installer tidies after itself, and is reported as routine rather than as a restart the system is waiting on. An entry that replaces a file in place is a genuine change and still counts as one.
  - The same list was read as a flat run of strings, so three operations were reported as the six slots they occupy whenever files were being replaced rather than deleted.

- **Restart and Shut Down Acting on Routine Cleanup (`core/RebootEngine.ps1`)**:
  - The Force, Shutdown and Schedule policies acted on any pending item, a temporary folder left behind by a browser update included. On an unattended schedule that closed applications without warning over a condition which returns on its own within hours, so a machine could restart repeatedly and never reach a state where it stopped.
  - Those three policies now act only when the system is genuinely part way through a change. Choosing Restart Now or Shut Down in the interface works exactly as before, because a person asking for a restart is not the same as a policy deciding on one.

- **Restart Policies That Reported Success Without Acting (`core/RebootEngine.ps1`)**:
  - Schedule reported that a restart had been scheduled and returned that result, but scheduled nothing. It now sets a restart at the configured quiet hour, which can be cancelled with `shutdown /a`.
  - Notify loaded a windowing library and then displayed nothing.
  - Prompt and Smart were offered in the settings and in the configuration file but had no implementation, so both fell through to a default without saying so. Prompt now asks, in whichever interface is running. Smart reports what is pending and never restarts on its own.

- **Restart Notices That Did Not Say What Was Pending (`core/RebootEngine.ps1`, `core/Engine.psm1`, `fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/app.js`)**:
  - A pending restart was reported as a count, leaving no way to tell a queued temporary folder from a system file waiting to be replaced without reading the registry by hand. The affected paths were collected and then discarded before they reached any interface.
  - The command line, the text interface and the notification centre now name what is pending.

- **Restart Conditions That Went Undetected (`core/RebootEngine.ps1`)**:
  - Staged servicing packages, updates awaiting a restart to finish installing, a pending computer rename, a pending domain join and an installer that stopped part way were never checked. A real pending restart could therefore be missed while routine cleanup was reported as one.

- **Notification Entries Rendering an Empty Control (`gui/app.js`)**:
  - An entry with nothing to offer still rendered a button, labelled with the text it did not have. Entries without an action now render without one.
  - Three handlers were bound to elements that no longer exist in the page and have been removed.

- **Uninstall Overrode the Choice It Offered (`install.ps1`, `gui/Server.ps1`, `gui/index.html`, `gui/app.js`)**:
  - The uninstall dialog offered a choice about restoring Windows defaults and the installer discarded it. The decision was initialised to restore, and the only branch that could change it required an interactive session, which an uninstall started from the desktop interface never is. Every uninstall therefore reverted the update settings, including one where the box had been cleared. Someone who installed FedUpDate to stop Windows restarting on its own, and who wanted to keep that after removing the application, had it taken back without being told.
  - The outcome is now an explicit value rather than a pair of switches with a fallback. An unattended run that does not state one is refused, because a machine's update policy is not something to be chosen on the owner's behalf.

- **Reverting Settings Failed Silently Without Administrator Rights (`core/RollbackEngine.ps1`, `fedupdate.ps1`)**:
  - The values FedUpDate writes live under HKLM, so reverting them needs elevation. Rollback never asked for any. Run from an ordinary session the writes failed behind a suppressed error and the caller reported that Windows defaults had been restored, when nothing had been. Choosing to restore during an uninstall therefore did nothing at all unless the session already happened to be elevated.
  - Rollback now asks for elevation and re-enters through the command line, which is how the anti-tamper watchdog has always handled the same problem. A declined prompt reports that nothing was reverted rather than claiming success.
  - `fedupdate rollback -All` reverts every recorded transaction. It is the scope the uninstaller uses and the one the elevated re-entry returns through.

- **The Alias Was Left Behind in Another Host's Profile (`install.ps1`)**:
  - `$PROFILE` resolves differently per host: PowerShell 7 uses `Documents\PowerShell` and Windows PowerShell uses `Documents\WindowsPowerShell`. Uninstall cleaned only the profile belonging to whichever host it happened to run under, so an installation made from one and removed from the other left a `fedupdate` function behind pointing at a directory that no longer existed, and every new session in that host reported a broken command.
  - Uninstall now clears the alias from every profile an installation could have written to, covering both hosts, both profile file names and a redirected Documents folder.

- **Uninstall Left the Application Behind (`install.ps1`)**:
  - Nothing removed the installation directory or the desktop interface's browser profile, while the closing message reported that the removal had completed. A directory cannot be deleted by the process standing in it, so removal is now handed to a detached step that waits for the uninstaller to exit and then clears both paths, retrying while the last file handles are released.
  - The uninstall command was also assembled by joining its arguments into a single string, which would have split an installation path containing a space into separate arguments.

### Added

- **Restart Status Separates Required From Routine (`core/RebootEngine.ps1`, `fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/app.js`, `gui/index.html`, `gui/styles.css`)**:
  - A scan reports one of three states rather than a yes or a no. The command line labels the state and lists the affected paths, the text interface carries a third badge for queued cleanup, and the notification centre presents routine cleanup as an informational entry with no restart controls, keeping the urgent entry for a restart the system is genuinely waiting on.

- **Correlation With the Last Restart (`core/RebootEngine.ps1`)**:
  - Pending work is dated against the last restart. Anything older has already survived one, and every interface now says so, instead of leaving a restart that cannot resolve the condition as the only thing on offer.

- **Reboot Engine Checks (`audit/audit-reboot.ps1`)**:
  - Forty four checks covering the parsing, the grading and every policy branch. They grade captured data rather than the machine they run on, and the policies reach their restart, shutdown and scheduling calls through stand ins, so no check is able to restart or shut anything down.

- **Uninstall Decision Checks (`audit/audit-uninstall.ps1`)**:
  - Thirty one checks covering every combination of switches the interfaces can send, including the ones that previously reverted the settings regardless of what was chosen, along with the elevation path and the profile cleanup. The decision is evaluated rather than executed, so no check uninstalls anything.

### Changed

- **Default Restart Policy (`core/Config.ps1`, `gui/index.html`)**:
  - A new installation defaults to Smart, which reports what is pending and leaves the decision to you. An existing configuration file is left as it is.

- **Uninstall Presents Three Outcomes (`install.ps1`, `gui/index.html`, `gui/styles.css`)**:
  - Restore Windows defaults, or keep the settings and keep the ledger, or keep the settings and delete the ledger. Keeping the settings while deleting the ledger leaves changes on the machine with no record of what they were, so it is now a deliberate choice with its consequence stated rather than a combination of two boxes that happened to produce it.
  - The dialog and the prompt both state that the on-boot enforcer is removed with the application, so settings that are kept are no longer maintained and Windows may revert them later.

---

## [0.5.6-beta] - 2026-08-22

### Added

- **External Links Open in the Browser (`gui/src/Program.cs`)**:
  - The host now intercepts navigation and window requests, sending any address outside the local interface to the default browser. Without this a link would either replace the application window with a web page or raise a window with no controls.
  - Only http and https addresses are passed to the shell, so a crafted link cannot be used to start an arbitrary local program.
- **Full Changelog Link (`gui/index.html`, `gui/styles.css`)**:
  - The title in the version panel opens the project's releases page, for readers who want the complete history rather than the versions between theirs and the latest.
- **Expandable Release Indicator (`gui/app.js`, `gui/styles.css`)**:
  - Each release heading carries a chevron that turns when the entry is open, so a collapsed release reads as something that can be opened rather than a dead row.

---

## [0.5.5-beta] - 2026-08-22

### Fixed

- **Dashboard and Notifications Not Refreshing After an Update (`gui/app.js`)**:
  - Starting an update returns as soon as the run has been handed to a background runspace. The interface treated that reply as completion, so it announced success while the work was still in progress and then refreshed from state gathered before anything had been installed. The counts and notifications therefore stayed as they were.
  - The interface now waits for the run to report that it has finished before refreshing. Because reading that status is also what makes the completed run's results available, polling is what allows the refreshed view to reflect the work that was done.
  - A run that exceeds the engine's own thirty minute ceiling is reported as still running rather than as complete.

---

## [0.5.4-beta] - 2026-08-22

### Fixed

- **Spurious Elevation Warning During Scans (`core/OSUpdateEngine.ps1`)**:
  - A scan warned that results might be incomplete whenever the Windows Update service was not running, then completed correctly. The service is trigger-started, so a stopped service with a Manual start type is brought up on demand and needs neither intervention nor elevation.
  - The warning is now raised only when the service is genuinely disabled, which is the one state that prevents a scan from returning what is pending.

---

## [0.5.3-beta] - 2026-08-22

### Fixed

- **Update Run Stalled Instead of Installing (`core/OSUpdateEngine.ps1`)**:
  - The install path called the Update Agent search directly. That call blocks indefinitely while Windows is busy, so an update run logged that it was preparing and then produced nothing further: no progress, no error, and nothing installed. The scan already guarded the same call with a bounded job.
  - The Update Agent conversation now runs inside a job with a thirty minute ceiling. Update Agent objects cannot cross a job boundary, so the session, search, download and install all take place within it and only the outcome is returned. A timeout is reported rather than waited on forever.
  - Installing requires elevation, which the run did not request. It now prompts through UAC in the same way the Anti-Tamper Watchdog does, and reports clearly when elevation is declined.

---

## [0.5.2-beta] - 2026-08-22

### Fixed

- **Installing Updates While the Watchdog Is Active (`core/OSUpdateEngine.ps1`)**:
  - Only the scan borrowed the Windows Update service. Downloading and installing go through the same Update Agent, so with the watchdog enforced an update run could complete without applying anything.
  - The download and install operation now borrows the service for its duration and restores it afterwards, including when the run fails.

---

## [0.5.1-beta] - 2026-08-22

### Fixed

- **Version Glyph Sat Above the Corner (`gui/index.html`, `gui/styles.css`)**:
  - The glyph reserved the height of the docked drawer at all times, but the drawer is hidden entirely while idle, leaving the glyph floating well above the window corner.
  - It now rests in the corner and lifts clear of the drawer only while the drawer is on screen. The corner follows the drawer in the markup so this is expressed in the stylesheet rather than coordinated from script.

---

## [0.5.0-beta] - 2026-08-22

### Added

- **Version Corner and In-App Changelog (`gui/index.html`, `gui/styles.css`, `gui/app.js`, `gui/Server.ps1`, `core/Version.ps1`)**:
  - The repository glyph is anchored to the bottom right of the window on the Settings page, clearing the docked drawer. It carries the installed version on hover and pulses when a newer release exists.
  - Clicking it opens a panel upward, in the same manner as the notification centre, showing the installed and available versions with an update control.
  - The panel presents the release notes for every version between the installed one and the latest, so an update can be read and judged without leaving the application. The newest release is expanded and older ones collapse to their heading, keeping the panel a predictable size however far behind an installation is.
  - `Get-FedReleaseNotes` returns those notes, dropping the trailing bootstrap instructions: inside the application the update control is already present, so repeating the command is noise. The published release keeps it.
  - `GET /api/changelog` serves the notes and caches them for the life of the server process, as the unauthenticated GitHub API allows sixty requests an hour for the whole machine.

### Changed

- **Settings Layout (`gui/index.html`)**:
  - The version row that sat at the end of the Settings content is replaced by the corner glyph. The repository name, the update badge, and the update button now live inside the panel rather than beside the glyph.

---

## [0.4.4-beta] - 2026-08-22

### Fixed

- **Profile Alias Left Fragments Behind (`install.ps1`)**:
  - Uninstall removed the alias with a lazy multiline regex that matched only as far as the function name, leaving the body behind. An orphaned scriptblock literal is evaluated by PowerShell, so every new session printed it.
  - Install then checked for the function name that removal had just deleted, so each reinstall appended another copy and the fragments accumulated.
  - Removal is now line based and also clears fragments written by earlier builds, and install clears any existing hook before writing a new one so duplicates cannot stack.

---

## [0.4.3-beta] - 2026-08-22

### Fixed

- **Rollback Reapplying Enforced Policy (`core/RollbackEngine.ps1`)**:
  - Enforcing the watchdog while it was already enforced recorded entries whose original and new values were identical. Reverting such an entry wrote the enforced value back, so rolling back the full ledger reapplied the policy it was meant to remove. An uninstall could therefore leave Windows Update fully locked down in both `HKCU` and `HKLM` while reporting success.
  - Registry, service, and scheduled-task entries that record no actual change are now skipped during rollback, so a later transaction that correctly cleared a value is no longer undone by an earlier no-op.

---

## [0.4.2-beta] - 2026-08-22

### Fixed

- **Rollback of HKCU Policy Values (`core/RollbackEngine.ps1`)**:
  - `Record-FedRegistryChange` opened `LocalMachine` for every path, so an `HKCU:` key resolved to nothing and its value kind was never recorded. Rollback then failed on those entries with a type binding error, and uninstall reported success while leaving user policy in place.
  - The value kind is now read from the hive the path belongs to, for both `HKCU:` and `HKLM:` and their long forms.
  - Restore tolerates a missing value kind, inferring it from the recorded change instead of failing. Ledgers written before this fix can therefore still be rolled back.

---

## [0.4.1-beta] - 2026-08-22

### Fixed

- **Windows Update Scanning While the Watchdog Is Active (`core/OSUpdateEngine.ps1`)**:
  - The watchdog disables `wuauserv` by design, and the Windows Update Agent COM API needs it. A scan run in that state returned an empty result that was indistinguishable from genuinely having no updates, so enabling the shield made pending updates appear to vanish.
  - `Invoke-FedWithUpdateService` now starts the service for the duration of a query and restores its original start type and running state afterwards. The restore runs in a `finally` block, so a failed or interrupted scan cannot leave the service enabled and the shield silently off.
  - Without elevation the service cannot be started, so the scan reports that its result may be incomplete instead of returning a silent zero.
  - The search timeout is raised from 4 to 30 seconds. Four seconds was frequently shorter than a genuine online query, which was reported as the service being busy.

---

## [0.4.0-beta] - 2026-08-22

### Added

- **Version Awareness and Self-Update (`core/Version.ps1`)**:
  - The installed version is read from the topmost entry in `CHANGELOG.md`. That file already records every release, so the version cannot drift from the changelog: it is the changelog.
  - `Get-FedLatestRelease` queries the GitHub releases API, and `Compare-FedVersion` orders releases numerically with prerelease handling, so `0.10.0` is correctly newer than `0.9.0` and `1.0.0-beta` is older than `1.0.0`.
  - `Get-FedVersionStatus` reports the installed version, the published version, and whether an update is available. A failed network call is not an error: the installed version is still reported.
  - `Invoke-FedSelfUpdate` updates in place by re-running the published installer, which already upgrades an existing installation and preserves the `data/` directory. There is one upgrade path rather than a second that could diverge.
- **Version Surfaces Across All Three Interfaces**:
  - CLI: `fedupdate version` shows the installed version and checks for a newer release; `fedupdate self-update` installs it. Both support `-WhatIf`.
  - TUI: the banner reads the real version, and menu option 9 checks for and applies updates.
  - GUI: `GET /api/version` and `POST /api/self-update`, with the remote check cached per server process so opening Settings repeatedly does not repeatedly call the GitHub API.
  - GUI Settings shows a GitHub link with the repository glyph. When a newer release exists the glyph pulses, an update badge appears, and an update button is offered.

### Fixed

- **Hardcoded Version Strings (`gui/index.html`, `tui/TuiEngine.ps1`)**:
  - The GUI titlebar badge and the TUI banner both displayed a literal `v0.1.0-beta` that was never updated and did not reflect the running release. Both now read the real version.

### Removed

- **Dead Code**:
  - `mockInitialData()` in `gui/app.js`, which held placeholder package rows with fabricated version numbers. It was defined but never called.
  - The `version` field from `Get-FedDefaultConfig` (`core/Config.ps1`). It was written into `config.json` on first run and never read back, so it recorded whichever version created the file rather than the version in use.

---

## [0.3.2-beta] - 2026-08-22

### Changed

- **Notification Centre Height (`gui/styles.css`)**:
  - `--sys-dim-flyout-max-height` is derived from the window rather than fixed at `22rem`: `calc(100vh - var(--sys-dim-titlebar-height) - var(--sys-dim-dock-height) - var(--sys-space-xl))`. The flyout now grows with its contents until it reaches the docked drawer, instead of stopping at a constant height regardless of how much room the window offers.
  - The limit moved from `.notif-flyout-list` to `.notif-flyout`, so the header counts toward it and the outer edge is what stops above the dock.
  - The list takes the remaining space with `flex: 1 1 auto` and `min-height: 0`, which allows it to shrink below its content and engage its own scrollbar.

---

## [0.3.1-beta] - 2026-08-22

### Fixed

- **Shortcut Creation on Redirected User Folders (`install.ps1`)**:
  - Start Menu and Desktop locations are resolved through the Windows special-folder API rather than assumed to sit under `%USERPROFILE%`. Where OneDrive Known Folder Move has redirected the Desktop, the literal path does not exist and shortcut creation failed.
  - Each shortcut is created independently, so a failure on one no longer prevents the other from being written.
  - Uninstall resolves the same locations, so redirected shortcuts are removed cleanly.
- **Shortcut Target (`install.ps1`)**:
  - Start Menu and Desktop shortcuts launch `gui/bin/FedUpDate.UI.exe` directly, so they open the frameless application window and take their icon from the executable's embedded resource. They previously ran the VBS launcher, which serves the interface through Edge in app mode: that window carries a native title bar above the in-app one, and the shortcut icon came from `wscript.exe`.
  - The VBS launcher remains the fallback when the GUI has not been compiled, with the application icon set explicitly.

### Changed

- **Uninstall Prompt Defaults (`install.ps1`)**:
  - Both questions accept Enter. Restoring Windows Update services and settings defaults to yes, shown as `[Y/n]`; keeping backup snapshots and logs defaults to no, shown as `[y/N]`.
  - Unrecognised input re-asks instead of falling through to a branch that was not chosen.
  - A non-interactive uninstall now restores Windows Update defaults as well, so an unattended removal cannot leave update services disabled.

---

## [0.3.0-beta] - 2026-08-21

### Added

- **Remote Bootstrap Installation (`install.ps1`)**:
  - The installer now runs directly from the network with no files on disk: `irm https://raw.githubusercontent.com/Arelius-D/FedUpDate/main/install.ps1 | iex`.
  - Source-only distribution: the installer downloads the project source archive, never a packaged installer or a prebuilt binary. The command fetches a plain PowerShell script that can be read in full before it is run.
  - Compiles the desktop GUI locally during installation, using the C# compiler that ships with the .NET Framework on every Windows 10/11 machine, so no developer tooling is required. The only binaries involved are Microsoft's WebView2 libraries, fetched from Microsoft's NuGet CDN.
  - A failed or skipped GUI build is non-fatal and reports the two commands that retry it. The CLI and TUI are pure PowerShell and require no compilation.
  - Added `-Branch` to install from a specific source branch and `-SkipGuiBuild` to bypass compilation.
  - Unpacks to `%LOCALAPPDATA%\Programs\FedUpDate` by default, overridable with `-InstallPath`.
  - Added `-FromPath` to install from an already-downloaded copy without any network access.
  - Detects an existing installation and upgrades it in place, leaving the `data/` directory untouched so configuration, logs, the state ledger, and rollback snapshots survive upgrades.
  - Unwraps the single nested directory present in GitHub source archives (`FedUpDate-main/`) before installing.
  - Resolves installation paths from a verified payload root, so the User PATH entry, profile alias, and shortcuts register against the real install directory in every mode.
  - Uninstall locates an existing installation through the script directory, `-InstallPath`, the default install location, or the User PATH.
  - Running from a complete local copy continues to install in place exactly as before.
- **WebView2 SDK Restore from NuGet (`gui/SetupLibs.ps1`)**:
  - Retrieves the managed WebView2 assemblies (`lib/net462`) and the x64 native loader (`runtimes/win-x64/native`) from the official `Microsoft.Web.WebView2` package on nuget.org, keeping `gui/lib` and `gui/bin` on a single pinned version.
  - Resolves the newest stable version automatically, skipping prerelease builds; a specific version may be pinned with `-Version`.
  - Requires no NuGet client, .NET SDK, or Visual Studio: a `.nupkg` is an ordinary ZIP archive, so `Invoke-WebRequest` and `Expand-Archive` are sufficient.
  - Skips the download when the libraries are already present unless `-Force` is supplied.
  - Restores into `gui/bin` only. A second copy was previously written to `gui/lib`, which no build or runtime path reads.
- **Windows 11 Rounded Window Shell (`gui/src/Program.cs`)**:
  - The frameless host window now opts into the Windows 11 rounded shell, setting `DWMWA_WINDOW_CORNER_PREFERENCE` (attribute 33) to `DWMWCP_ROUND` once the window handle becomes available.
- **GitHub Repository Metadata (`.github/FUNDING.yml`, `.gitattributes`)**:
  - Added a funding manifest listing the project's GitHub Sponsors account.
  - Added `.gitattributes` normalising the tree to CRLF and marking image and binary types, so the `.cmd` and `.vbs` launchers keep correct line endings when the installer extracts a downloaded source archive on a user's machine.
- **`CONTRIBUTING.md` and `SECURITY.md`**:
  - Contribution guide covering the noncommercial licence terms that apply to submitted work, the build steps, and the requirement that both audits pass before a pull request.
  - Security policy documenting private vulnerability reporting, the registry, service, and scheduled-task changes the watchdog makes, the rollback paths that reverse them, and what is in and out of scope.
- **`LICENSE`**:
  - Added the PolyForm Noncommercial License 1.0.0 with the project copyright notice.

### Changed

- **Silent On-Boot Watchdog Guard (`core/AntiTamperWatchdog.ps1`)**:
  - `FedUpDate-Watchdog-Enforcer` is now registered under the SYSTEM account with `New-ScheduledTaskPrincipal -LogonType ServiceAccount -RunLevel Highest`, matching the update scheduler. The guard runs in session 0, so signing in no longer flashes a console window or raises a UAC prompt.
  - The trigger is now `-AtStartup`, enforcing machine-wide policy before any user signs in, rather than once per interactive logon.
  - Registration requires an elevated session and reports clearly when elevation is missing, instead of registering a task that cannot apply HKLM policy.
  - `-WhatIf` now reports the executable and arguments that are actually registered; the simulated and real registration paths previously differed.
- **Documented CLI Syntax (`README.md`, `fedupdate.ps1`)**:
  - Command examples and the built-in `help` output now use PowerShell parameter syntax (`-All`, `-WhatIf`, `-Latest`, `-Count`). The previously documented double-dash forms do not bind: value flags such as `--count 50` raise a parameter error, and switches such as `--all` and `--latest` were absorbed as a positional argument and silently ignored.
  - The help listing covers every routed command and its columns are aligned.
- **Single Simulation Flag (`fedupdate.ps1`, `tui/TuiEngine.ps1`, `gui/index.html`, `gui/app.js`)**:
  - Removed the `-DryRun` switch and its `simulate` alias. `-WhatIf` is the one simulation flag, matching PowerShell convention and the engine layer, which already used `-WhatIf` exclusively.
  - The TUI menu, the GUI action button, and the log-level filter now read WhatIf rather than mixing both names.
  - The `WHATIF` log level and the `whatif` field in the local GUI API are unchanged, so simulation output and the GUI request contract behave exactly as before.
- **Project License (`README.md`, `LICENSE`)**:
  - Relicensed from MIT to PolyForm Noncommercial License 1.0.0. Use, modification, and redistribution remain free for any noncommercial purpose; commercial use is not permitted.
- **Repository Exclusions (`.gitignore`)**:
  - Excluded `data/config.json`. Configuration is generated on first run by `Get-FedDefaultConfig` (`core/Config.ps1`), so every installation starts from the documented defaults.
  - Excluded `gui/lib/` and `gui/bin/*.dll`. WebView2 libraries are restored at build time by `gui/SetupLibs.ps1`.
  - Narrowed the build-artifact rules to compiled output. A directory-wide `bin/` pattern also matched `gui/bin/`, which would have withheld `gui/bin/build.ps1` — the script that compiles the GUI during installation — from the published source.
  - Excluded `audit/` (internal development reports and tooling), `archive/` (retired files kept locally for reference), and the `dist/` and `release/` packaging directories.
- **Design System Audit Scope (`audit/audit-css.ps1`)**:
  - LAW 22 (Native Host DWM Shell Compliance) now validates `gui/src/Program.cs`, the compiled host that ships, confirming both `WindowChrome` and the rounded corner preference.
- **Syntax Audit Reporting (`audit/audit-syntax.ps1`)**:
  - Results are sorted and reported as project-relative paths, so identically named scripts in different directories (`gui/build.ps1` and `gui/bin/build.ps1`) stay distinguishable.
  - `archive/` is excluded from the gate: retired code is kept for reference only and can no longer fail the audit.
- **Removed `gui/lib/`**:
  - The directory held a duplicate set of WebView2 assemblies read only by the retired PowerShell host. `gui/bin` is the single location for build and runtime libraries.
- **Retired `gui/Host.ps1`**:
  - The legacy PowerShell WPF host is superseded by `gui/src/Program.cs`, compiled as `FedUpDate.UI.exe`. It is retained locally under `archive/` for reference and excluded from the repository.
- **Default Configuration Version (`core/Config.ps1`)**:
  - `Get-FedDefaultConfig` now reports `0.3.0-beta`, matching the release.
- **Documented Architecture (`README.md`)**:
  - The directory tree reflects the current GUI layout.

---

## [0.2.0-beta] - 2026-08-19

### Added

- **"Update & Shut Down" / Direct Power Management Suite (`core/RebootEngine.ps1`, `gui/Server.ps1`, `fedupdate.ps1`, `gui/app.js`, `gui/index.html`)**:
  - Added dedicated system shutdown power action alongside reboot, allowing users to finalize pending updates and turn off their PC cleanly.
  - Added `POST /api/reboot/shutdown` server endpoint invoking `Invoke-FedRebootPolicy -PolicyOverride "Shutdown"`.
  - Added `Shutdown` case to `core/RebootEngine.ps1` calling `Stop-Computer -Force`.
  - Added `Update & Shut Down` option to the Reboot Enforcement Policy settings dropdown (`#rebootPolicySelect`).
  - Added `-Shutdown` switch parameter to CLI (`fedupdate.ps1 update -All -Shutdown`).
  - Dual action buttons rendered side-by-side in Notification Center when a reboot is pending: **Restart Now** and **Shut Down**.
- **Per-Level "Clear View" Log Management (`gui/app.js`)**:
  - Implemented granular per-level clearance tracking (`state.clearedLevels`).
  - Clearing logs while filtered by a specific severity (e.g. `ERROR`, `WARN`, `INFO`, `SUCCESS`, `WHATIF`) clears only that level, preserving all other log streams.
  - Selecting `ALL` clears the entire terminal buffer.
- **Dynamic Level-Filtered Log Export (`gui/app.js`)**:
  - Export now respects the active dropdown filter, exporting only the visible/selected severity levels.
  - Automatically generates descriptive, timestamped filenames: `fedupdate-logs-<filter>-<timestamp>.log` (e.g. `fedupdate-logs-error-2026-08-19T22-33-00.log`).
- **High-Definition Title Bar Branding (`gui/index.html`, `gui/styles.css`)**:
  - Replaced generic placeholder SVG icon with the master transparent icon (`assets/fedupdate-icon.png`) with strict tokenized sizing and `object-fit: contain;`.
- **Automatic Administrator UAC Elevation for Watchdog Enforcement (`core/AntiTamperWatchdog.ps1`)**:
  - Detects elevation status on `Enforce-FedWatchdog`. When running non-elevated, prompts via UAC (`Start-Process -Verb RunAs`) to write HKLM Group Policies and register system-wide Scheduled Tasks with graceful direct-execution fallback.

### Fixed

- **Terminal Scroll-Lock & Idle DOM Thrashing (`gui/app.js`)**:
  - Fixed the 600ms scroll jumping bug where the terminal would repeatedly pull the scrollbar back down to the bottom while idle.
  - Implemented signature hashing (`state.lastLogSig`): DOM is not re-rendered when no new log lines have arrived.
  - Implemented scroll proximity detection (`scrollHeight - scrollTop - clientHeight < 40`): Terminal only auto-scrolls if the user was already at the very bottom, allowing smooth inspection and reading at any scroll position.
- **Anti-Tamper Drift Audit False-Positive Clearance (`core/AntiTamperWatchdog.ps1`, `core/Config.ps1`)**:
  - Aligned Delivery Optimization configuration (`disableDeliveryOptimization = false`) with Windows 11 Microsoft Store streaming requirements, eliminating recurring service drift notifications.
  - Refined boot persistence task verification to prevent optional task states from triggering false policy drift alarms.
  - Verified 100% hardened compliance with zero drift (`Policy Drift Detected: False`).
- **HKLM & HKCU Registry Key Creation (`core/RollbackEngine.ps1`)**:
  - Replaced basic PowerShell `New-Item` with .NET `[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey` and `LocalMachine.CreateSubKey` to create nested Group Policy registry paths without access exceptions.
- **Notification Action Routing & Client State Synchronization (`gui/app.js`)**:
  - Fixed single-quote HTML escaping for `window.navigateTo('packages')` and `window.navigateTo('osupdates')`.
  - Added instant package state recalculation upon upgrading (filters upgraded packages, decrements badge counts, and dismisses notifications immediately).
  - Added "Clear" / dismiss-all button to the notification flyout header (`#notifDismissAllBtn`).
- **Startup Splash Screen & Frame Transition (`gui/src/Program.cs`)**:
  - Eliminated the intermediate black frame on startup by initializing WebView2 directly with solid theme canvas and smooth 2.5s branding splash presentation.

### Removed

- **Obsolete Scratchpad Reference Files**:
  - Deleted `themes.md` (initial LucID theme reference document).
  - Deleted `UI and UX stuff.md` (initial WinUI 3 architecture draft).
  - Deleted `core functions.md` (initial brainstorming notes).

---

## [0.1.0-beta] - 2026-08-16

### Fixed

- **API Scan Data Hydration & Background Job Dispatch (`gui/Server.ps1`, `gui/app.js`)**:
  - Re-architected `/api/scan` in `gui/Server.ps1` to accurately extract the final audit summary PSCustomObject from the PowerShell Runspace result stream, resolving the issue where UI scan was waiting on empty arrays.
  - Automatically triggers background system audit at server boot, populating live update badges and package tables immediately.
- **WinGet Engine Output Parsing (`core/WingetEngine.ps1`)**:
  - Added strict non-empty string validation for package names, IDs, and versions to prevent phantom whitespace rows.
- **Anti-Tamper Watchdog Scheduled Task Query (`core/AntiTamperWatchdog.ps1`)**:
  - Replaced CLI string queries with native PowerShell `Get-ScheduledTask` to prevent `NativeCommandError` failures under strict `$ErrorActionPreference = "Stop"`.
- **Same-Origin API Communication & Live Data Hydration (`gui/src/Program.cs`, `gui/app.js`)**:
  - Routed WebView2 navigation directly to the local API server origin (`http://localhost:$port/`), completely eliminating Chromium Mixed Content blocks.
  - Live system audit scans now immediately populate all dashboard cards, pending Windows Update KBs, WinGet packages, Store state, and live terminal logs.
- **Terminal View Theming in Light Mode (`gui/styles.css`)**:
  - Styled `.terminal-container`, `.terminal-toolbar`, and `.terminal-body` using design tokens (`var(--sys-color-surface-card)`), eliminating the unwanted dark background in light theme.
- **Task Progress Dock Idle Management (`gui/styles.css`, `gui/app.js`)**:
  - Configured `#taskProgressDock` to hide completely (`.dock-idle`) when the system is idle, removing the perpetual indeterminate animation bar.
- **File-Backed Persistent Logging (`core/Logger.ps1`)**:
  - Enhanced `Get-FedLogs` to read historical logs from `data/logs/fedupdate.log` when starting fresh.

### Added

- **Native Compiled Standalone Desktop Executable (`gui/bin/FedUpDate.UI.exe`, `fedupdate.ps1 gui`)**:
  - Standalone native C# WPF desktop executable targeting .NET Framework 4.8 and bundling WebView2.
  - Zero OS title bar at the Desktop Window Manager (DWM) level.
  - In-app Fluent caption controls (`#winMinBtn`, `#winMaxBtn`, `#winCloseBtn`) are the sole window controls on screen.
- **Design System Audit & Compliance Suite ([`audit/CSS_AUDIT.md`](audit/CSS_AUDIT.md), [`audit/audit-css.ps1`](audit/audit-css.ps1))**:
  - Mechanical automated audit passing with zero `!important` declarations, zero fixed `px` units, zero inline style violations, and 100% OKLCH color space verification.
- **OS Default Theme Detection & Synchronization**:
  - Automatically queries the Windows OS system theme (`prefers-color-scheme: light/dark`) on initial application launch and defaults to the user's OS preference.
  - Dynamically responds to real-time OS theme switching.
- **Full 100% Clean Uninstallation Suite (`install.ps1 -Uninstall`, `fedupdate uninstall`, UI Settings Modal)**:
  - Clean removal engine unregistering PATH entries, profile integrations, scheduled tasks, and shortcuts.
- **State Ledger, Backup & Rollback Engine (`core/RollbackEngine.ps1`)**:
  - Timestamped state snapshots (`data/state_ledger.json` and `data/backups/`) for all registry, service, and task modifications.
- **Core Update Orchestration Engines**:
  - `core/OSUpdateEngine.ps1`: Direct Windows Update Agent COM integration.
  - `core/WingetEngine.ps1`: Structured WinGet package manager scanner and updater.
  - `core/StoreEngine.ps1`: Microsoft Store update trigger via WMI/CIM MDM Enterprise sync.
  - `core/RebootEngine.ps1`: Multi-registry pending reboot detection.
  - `core/AntiTamperWatchdog.ps1`: Auditing and disabling of intrusive Windows Update auto-reboot tasks and background hijacking services.
- **Standalone Build Automation Tooling (`gui/bin/build.ps1`, `gui/build.ps1`)**:
  - Added dedicated one-command compilation scripts invoking the platform C# compiler (`csc.exe`) with all required assembly references to rebuild `FedUpDate.UI.exe` deterministically without external build dependencies.
  - Implemented dynamic runtime discovery in `build.ps1` to detect the latest available `csc.exe` (PATH, Visual Studio / MSBuild Roslyn, Framework64/Framework) and WPF assembly directories with zero hardcoded path strings.
- **LucID Flagship Design System Integration: Dusk Ember & Warm Linen (`gui/styles.css`, `gui/src/Program.cs`)**:
  - Implemented full 100% OKLCH color token architecture from `themes.md`.
  - **Dusk Ember (`dusk-ember` / Dark default)**: Deep slate-charcoal canvas (`oklch(0.239 0.014 267)`), matte panel surfaces, and radiant metallic warm gold/amber brand accents (`oklch(0.773 0.14 78.6)`).
  - **Warm Linen (`warm-linen` / Light flagship)**: Warm artisanal linen canvas (`oklch(0.976 0.026 92.4)`), deep espresso typography (`oklch(0.267 0.019 84.5)`), and antique caramel-bronze brand accents (`oklch(0.643 0.055 81.4)`).
  - Verified 100% WCAG 2.1 AA contrast compliance and passed mechanical CSS audit with zero `!important` declarations, zero raw `px`, and 100% OKLCH color space.
- **Safe Ephemeral Port Allocation Range (`gui/Server.ps1`, `gui/src/Program.cs`, `gui/app.js`)**:
  - Migrated HTTP server and WebView2 navigation from restricted X11 port range (`6000-6050`) to safe ephemeral range (`58100-58150`), eliminating Chromium's `ERR_UNSAFE_PORT` error completely.
- **Asynchronous Non-Blocking Engine Scanning & Real-Time Log Streaming (`gui/Server.ps1`, `gui/app.js`)**:
  - Re-architected `/api/scan` and `/api/update` to execute on background threads via `ThreadPool`, eliminating server loop freezing and allowing `/api/logs` to stream live system events in real-time.
  - Initialized `startLogPolling()` immediately on DOM load so the terminal stream is populated from startup.
- **Navigation Toggle & Progress Dock Alignment (`gui/index.html`, `gui/styles.css`)**:
  - Moved the hamburger navigation toggle button `#navToggleBtn` directly into the top of `.nav-rail`, aligning it in the same vertical column with all navigation tab icons.
  - Re-anchored `#taskProgressDock` inside the content viewport and applied `.dock-idle` hiding by default, eliminating mismatched border outlines.
- **Terminal View Theming in Light and Dark Modes (`gui/styles.css`)**:
  - Styled `.terminal-container`, `.terminal-toolbar`, `.terminal-body`, and `.term-title` with semantic surface and typography tokens (`--sys-color-surface-card`, `--sys-color-surface-terminal`, `--sys-color-text-primary`), ensuring both Light (Warm Linen) and Dark (Dusk Ember) modes render properly.
- **Microsoft Store Pending App Scanner Integration (`core/StoreEngine.ps1`, `core/Engine.psm1`, `gui/app.js`)**:
  - Added pending Microsoft Store app detection via `winget upgrade --source msstore --disable-interactivity`.
  - Displayed real-time pending Store update counts in the dashboard Store card and badges.
- **WinGet Engine Non-Interactive Execution & Path Resolver (`core/WingetEngine.ps1`)**:
  - Added `--disable-interactivity` flag to WinGet upgrade queries, preventing escape-code table corruption and spinner hang in headless background processes.
  - Added fallback search for `winget.exe` in `Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*`.
- **Anti-Tamper Shield State Handling & Safe Fetch Bridge (`gui/app.js`)**:
  - Fixed `runWatchdogAudit()` state initialization to prevent `null` property reference errors on cold startup.
- **Stationary Navigation Rail Alignment (`gui/styles.css`)**:
  - Fixed navigation item layout so icons remain 100% stationary (0px horizontal or vertical movement) when collapsing or expanding the sidebar.
- **Engine Script ASCII Encoding & Parser Fixes (`core/WingetEngine.ps1`, `core/StoreEngine.ps1`)**:
  - Replaced non-ASCII Unicode separator characters (`─`) with standard ASCII delimiters (`-`), resolving PowerShell script parser failures across all Windows execution environments.
- **Full CLI Operations & Verification Suite Validation (`fedupdate.ps1`)**:
  - Validated all core CLI modes directly on host system:
    - `.\fedupdate.ps1 watchdog audit` -> Returns complete 4-point anti-tamper posture audit with exit code 0.
    - `.\fedupdate.ps1 scan` -> Correctly returns parsed counts across Windows Update (0), WinGet (1: Meld), and Store (0), plus multi-registry reboot diagnostics.
    - `.\fedupdate.ps1 update -WhatIf` -> Simulates full 6-phase pipeline across Defender, OS updates, WinGet packages, MDM Store sync, Anti-Tamper enforcement, and reboot policies with exit code 0.
- **Native Win32 Window Manager: Dragging, Resizing & Full Maximization (`gui/src/Program.cs`)**:
  - Implemented native `ReleaseCapture` + `SendMessage(WM_NCLBUTTONDOWN, HTCAPTION)` title bar dragging, bypassing WebView2 input capture limitations.
  - Implemented `HwndSource` `WndProc` hook with `WM_NCHITTEST` supporting edge and corner drag-resizing in all directions with 8px grab boundaries.
  - Resolved window maximize snap-back by properly binding `ResizeMode.CanResize` and `WindowChrome`.
- **Custom Fluent Select Dropdown & Input System (`gui/styles.css`)**:
  - Created bespoke themed styling for all `<select>`, `<option>`, and `.fluent-select` form elements matching **Dusk Ember** and **Warm Linen** palettes with custom SVG chevrons, focus rings, and hover states.
- **PowerShell Runspace Isolated Background Execution (`gui/Server.ps1`)**:
  - Migrated background scan and update routines from uninitialized .NET ThreadPool workers to dedicated PowerShell Runspaces, resolving `Start-FedScan` missing cmdlet errors in the GUI server.
- **Manual Dashboard Scan Action (`gui/index.html`, `gui/app.js`)**:
  - Added dedicated "Scan for Updates" button to the unified dashboard header.
- **PSScriptAnalyzer & IDE Linter Cleanup Across All Core Scripts**:
  - Removed invalid `Export-ModuleMember` invocations from all dot-sourced `.ps1` files (`OSUpdateEngine.ps1`, `StoreEngine.ps1`, `WingetEngine.ps1`, `Scheduler.ps1`, `RollbackEngine.ps1`, `RebootEngine.ps1`, `Logger.ps1`, `Config.ps1`, `AntiTamperWatchdog.ps1`), consolidating all public exports strictly in `core/Engine.psm1`.
  - Replaced legacy `Get-WmiObject` with modern `Get-CimInstance` in `StoreEngine.ps1`, eliminating `PSAvoidUsingWMICmdlet` warnings.
- **Sub-Second Fast Scan Optimization (`core/OSUpdateEngine.ps1`, `core/StoreEngine.ps1`)**:
  - Configured Windows Update COM search to query local cached catalog first with fallback, preventing multi-minute cloud handshake lockups on GUI startup.
  - Added 3.5s timeout guard and fast-path AppX status check in `StoreEngine.ps1` to prevent `winget upgrade --source msstore` from blocking background operations.
