-- Make Mail Draft
--
-- Takes a plain text file whose first lines are email headers, and opens a
-- new message in Mail with the To, Cc, Bcc, Subject, body and attachments
-- already filled in.
--
-- It never sends anything. The compose window opens for you to check.
--
-- Expected file format. Front matter fenced by --- lines, then the body:
--
--     ---
--     To: someone@example.com, another@example.com
--     Cc: colleague@example.com
--     From: sender@example.com
--     Subject: Re: Project Update
--     Attach: document.pdf, docs/report.pdf
--     ---
--
--     Hello,
--
--     Thanks for the **update**. Two things:
--
--     - The review is complete, dated 12 March 2026
--     - The revised schedule is attached
--
--     See [the project](https://example.com/project).
--
-- FORMATTING. The body is treated as Markdown by default and arrives in Mail
-- properly formatted — real bold, real bullets, real clickable links.
--
--     **bold**              bold
--     *italic*              italic
--     - item                bullet list  (also * item or + item)
--     1. item               numbered list
--     [text](url)           clickable link
--     # / ## / ###          headings, in restrained sizes
--     > quoted              indented quote
--     ---                   horizontal rule
--
-- Underscores are NOT italic markers, so file_names and folder names such as
-- _sent-emails survive untouched.
--
-- Put "Format: plain" in the front matter to switch all of that off and have
-- the body go in exactly as typed.
--
-- The older layout — headers, one blank line, body, with no --- fences — is
-- still accepted, so every email already in _sent-emails works untouched.
--
-- How the formatting works: the body is converted to ordinary HTML (p, ul, ol,
-- li, b, a) and pasted as public.html. RTF is not used — Mail's RTF paste
-- resets numbered lists. The paste needs Accessibility permission (System
-- Settings > Privacy & Security > Accessibility > add this app). Without it
-- the draft is still created, just as plain text, and you are told why.
--
-- From: is optional. If given, and it matches one of your Mail accounts,
-- the message is sent from that account.
--
-- Attach: is optional. Paths must stay inside the project folder
-- (the parent of Email/). Prefer Documents/file.pdf from the project root.
-- Absolute paths are allowed only when they resolve under that project.
--     project Documents/                        Documents/certificate.pdf
--     next to the .md                           certificate.pdf
-- Filenames containing commas should be wrapped in double quotes.
-- Anything that can't be found is reported at the end; the draft is still made.
--
-- Handler names are all prefixed mmd so they cannot clash with AppleScript's
-- own vocabulary.

property mmdMissing : {}
property mmdNotes : {}
property mmdAttachMismatch : false
property mmdAttachedCount : -1

-- A short record of the last run, written to /tmp/make-mail-draft.log. Only
-- of interest when something has gone wrong and you want to know which step.
property mmdLogText : ""

-- Mail composes in Helvetica 14. Lists and paragraphs share this style so
-- pasted HTML stays the same size as typed body text.
property mmdBodyStyle : "font-family:Helvetica,Arial,sans-serif;font-size:14px"


-- ENTRY POINT 1. Drag files onto the exported application.
on open theFiles
	set mmdMissing to {}
	set mmdNotes to {}
	set mmdAttachMismatch to false
	set mmdAttachedCount to -1
	set mmdLogText to ""
	mmdLog("run: dropped files")
	repeat with aFile in theFiles
		set thePath to POSIX path of (aFile as alias)
		mmdProcessPath(thePath)
	end repeat
	mmdWriteLog()
	mmdReportProblems()
end open


-- ENTRY POINT 2. Double-click, Script Editor Run, or:
--   osascript MakeMailDraft.applescript /path/to/one.md [/path/to/two.md …]
on run argv
	set mmdMissing to {}
	set mmdNotes to {}
	set mmdAttachMismatch to false
	set mmdAttachedCount to -1
	set mmdLogText to ""

	if (count of argv) > 0 then
		mmdLog("run: argv (" & (count of argv) & " paths)")
		repeat with aPath in argv
			mmdProcessPath(aPath as text)
		end repeat
		mmdWriteLog()
		-- When driven by MailExporter / MCP, return notes as text instead of a dialog.
		-- Exit 2 when Attach: count and Mail's draft disagree — never a silent OK.
		if mmdAttachMismatch then
			error mmdResultText() number 2
		end if
		return mmdResultText()
	end if

	mmdLog("run: double-clicked")
	set theChoice to button returned of (display dialog ¬
		"Make a Mail draft from:" buttons {"Cancel", "Clipboard", "Choose a file…"} ¬
		default button "Choose a file…" with title "Make Mail Draft")

	if theChoice is "Clipboard" then
		set rawText to (the clipboard as text)
		if rawText is "" then
			display dialog "The clipboard is empty." buttons {"OK"} default button 1
			return
		end if
		mmdMakeDraft(rawText, "")
	else if theChoice is "Choose a file…" then
		set aFile to (choose file with prompt "Choose an email text file")
		set thePath to POSIX path of (aFile as alias)
		try
			set fileText to (read (aFile as alias) as «class utf8»)
			mmdMakeDraft(fileText, mmdParentFolder(thePath))
		on error
			display dialog "That is not a text file, so there is no email in it to make." & ¬
				return & return & thePath buttons {"OK"} default button 1 ¬
				with title "Make Mail Draft" with icon caution
			return
		end try
	end if
	mmdWriteLog()
	mmdReportProblems()
end run


on mmdProcessPath(thePath)
	mmdLog("file: " & thePath)
	set fileText to ""
	set fileReadable to true
	try
		set fileText to (read (POSIX file thePath) as «class utf8»)
	on error
		set fileReadable to false
		mmdLog("  skipped: not readable as text")
		set end of mmdNotes to "Skipped " & thePath & " — that is not a text file. " & ¬
			"Attachments go on an Attach: line inside the email, not dropped on the app."
	end try
	if fileReadable then mmdMakeDraft(fileText, mmdParentFolder(thePath))
end mmdProcessPath


on mmdResultText()
	set theText to ""
	if (count of mmdNotes) > 0 then set theText to theText & mmdJoinLines(mmdNotes) & return & return
	if (count of mmdMissing) > 0 then
		set theText to theText & "These attachments could not be added:" & return & return & mmdJoinLines(mmdMissing)
	end if
	if mmdTrim(theText) is "" then return "OK"
	return theText
end mmdResultText


-- Does the actual work, given the text of an email file and the folder that
-- file came from (used to resolve relative attachment paths).
on mmdMakeDraft(rawText, baseFolder)
	set toList to {}
	set ccList to {}
	set bccList to {}
	set attachSpecs to {}
	set theSubject to ""
	set fromAddress to ""
	set theFormat to "markdown"
	set inReplyTo to ""
	set replyMode to "auto" -- auto | reply | reply-all | new
	set bodyLines to {}
	set inBody to false

	-- Two layouts are accepted.
	--
	-- Front matter, which is the one to write now:
	--     ---
	--     To: someone@example.com
	--     Subject: Something
	--     In-Reply-To: <message-id@example.com>
	--     Reply: reply-all
	--     ---
	--
	--     Hello,
	--
	-- And the original, headers then one blank line, which every email already
	-- in _sent-emails uses and which still works exactly as it did.
	--
	-- Inside front matter an unrecognised line is ignored rather than starting
	-- the body, so you can keep your own notes up there — Status:, Ref: and so
	-- on. Be aware that a mistyped Subjekt: is ignored just as quietly.
	set theLines to paragraphs of rawText
	set lineTotal to count of theLines
	set startAt to 1
	set usingFence to false

	repeat with i from 1 to lineTotal
		set firstReal to mmdTrim((item i of theLines) as text)
		if firstReal is not "" then
			if firstReal is "---" then
				set usingFence to true
				set startAt to i + 1
			end if
			exit repeat
		end if
	end repeat

	repeat with i from startAt to lineTotal
		set thisLine to (item i of theLines) as text

		if inBody then
			set end of bodyLines to thisLine
		else if usingFence and (mmdTrim(thisLine) is "---") then
			set inBody to true
		else if (not usingFence) and thisLine is "" then
			set inBody to true
		else
			set hName to mmdHeaderName(thisLine)
			set hValue to mmdHeaderValue(thisLine)

			-- AppleScript compares text without regard to case by default,
			-- so "To", "TO" and "to" all match here.
			if hName is "to" then
				set toList to mmdSplitAddresses(hValue)
			else if hName is "cc" then
				set ccList to mmdSplitAddresses(hValue)
			else if hName is "bcc" then
				set bccList to mmdSplitAddresses(hValue)
			else if hName is "subject" then
				set theSubject to hValue
			else if hName is "from" then
				set fromAddress to hValue
			else if hName is "format" then
				set theFormat to hValue
			else if hName is "in-reply-to" or hName is "reply-to-message-id" then
				set inReplyTo to hValue
			else if hName is "reply" then
				set replyMode to mmdTrim(hValue)
			else if hName is "attach" or hName is "attachment" or hName is "attachments" then
				-- may appear more than once, so add rather than replace
				repeat with oneSpec in mmdSplitList(hValue)
					set end of attachSpecs to (oneSpec as text)
				end repeat
			else if not usingFence then
				-- not a header we recognise, so the body has started
				set inBody to true
				set end of bodyLines to thisLine
			end if
		end if
	end repeat

	if usingFence and (not inBody) then
		set end of mmdNotes to "The front matter was opened with --- but never closed, so the whole file was read as headers and the email has no body."
	end if

	-- Drop the blank line that normally sits after the closing fence.
	repeat while (count of bodyLines) > 0 and mmdTrim(item 1 of bodyLines) is ""
		set bodyLines to rest of bodyLines
	end repeat

	set theBody to mmdJoinLines(bodyLines)

	-- Resolve the attachments before touching Mail, so we know what exists
	set foundFiles to {}
	repeat with oneSpec in attachSpecs
		try
			set resolved to mmdResolvePath(oneSpec as text, baseFolder)
			set end of foundFiles to (POSIX file resolved as alias)
		on error errMsg
			set end of mmdMissing to ((oneSpec as text) & "  (" & errMsg & ")")
		end try
	end repeat

	-- Decide whether we are going the formatted route. An empty body has
	-- nothing to format, and "Format: plain" opts out entirely.
	set wantsRich to (theFormat is not "plain") and (mmdTrim(theBody) is not "")
	set clipReady to false
	if wantsRich then set clipReady to mmdPutHTMLOnClipboard(mmdMarkdownToHTML(theBody))
	mmdLog("subject: [" & theSubject & "]  fenced: " & usingFence & ¬
		"  format: " & theFormat & "  clipboard ready: " & clipReady & ¬
		"  in-reply-to: [" & inReplyTo & "]  reply: " & replyMode)

	-- Build the message. Prefer a real Mail reply when In-Reply-To is set.
	if clipReady then
		set startingContent to ""
	else
		set startingContent to theBody
	end if

	set newMessage to missing value
	set usedReply to false

	if (replyMode is not "new") and (mmdTrim(inReplyTo) is not "") then
		set originalMsg to mmdFindMessageByID(inReplyTo)
		if originalMsg is missing value then
			set end of mmdNotes to "Could not find the original message for In-Reply-To: " & inReplyTo & ¬
				return & "A new draft was created instead (not threaded)."
			mmdLog("reply: original not found")
		else
			try
				tell application "Mail"
					activate
					if replyMode is "reply-all" or replyMode is "replyall" or replyMode is "all" then
						set newMessage to reply originalMsg reply to all true with opening window
					else
						-- auto / reply / anything else with an In-Reply-To
						set newMessage to reply originalMsg with opening window
					end if
				end tell
				set usedReply to true
				mmdLog("reply: opened threaded reply")
				-- Give Mail time to build the compose web body before we focus/paste.
				delay 1.0
			on error errMsg
				set end of mmdNotes to "Mail could not open a reply (" & errMsg & "). A new draft was created instead."
				mmdLog("reply: failed — " & errMsg)
				set newMessage to missing value
			end try
		end if
	end if

	if newMessage is missing value then
		tell application "Mail"
			activate
			set newMessage to make new outgoing message with properties ¬
				{subject:theSubject, content:startingContent, visible:true}
		end tell
		mmdApplyRecipients(newMessage, toList, ccList, bccList)
	else
		-- Threaded reply: override subject and To/Cc/Bcc from the .md when given.
		-- Mail's reply recipients come from the original message and are often wrong
		-- (e.g. replying to your own sent mail). Front-matter To/Cc/Bcc win.
		tell application "Mail"
			if theSubject is not "" then set subject of newMessage to theSubject
		end tell
		mmdApplyRecipients(newMessage, toList, ccList, bccList)
		-- Ensure something is on the clipboard for plain-text replies too.
		if not clipReady and (mmdTrim(theBody) is not "") then
			try
				set the clipboard to theBody
				set clipReady to true
				mmdLog("reply: plain body on clipboard for paste-at-caret")
			end try
		end if
	end if

	tell application "Mail"
		-- set the sending account if we can find a match, otherwise carry on
		if fromAddress is not "" then
			try
				repeat with acct in every account
					repeat with emailAddr in (email addresses of acct)
						if (emailAddr as text) is fromAddress then
							set sender of newMessage to ¬
								(full name of acct) & " <" & fromAddress & ">"
							exit repeat
						end if
					end repeat
				end repeat
			end try
		end if
	end tell

	-- After reply, Mail may title the window with Re: subject — use live subject
	-- for focus targeting.
	set focusSubject to theSubject
	try
		tell application "Mail" to set focusSubject to (subject of newMessage) as text
	end try

	-- Reply + attachments: AppleScript `make new attachment` wipes Mail's native
	-- quote/body. Paste our reply first, then attach via File → Attach Files…
	-- (GUI), which preserves text + cite quote and places files under our reply.
	set replyAttachPath to usedReply and ((count of foundFiles) > 0)

	if replyAttachPath then
		if not clipReady and (mmdTrim(theBody) is not "") then
			try
				set the clipboard to theBody
				set clipReady to true
			end try
		end if
		mmdReplyWithAttachments(newMessage, foundFiles, focusSubject, clipReady)
	else
		-- Paste the formatted body in. We only ever paste once we have positively
		-- identified the body area, so a failure here can never dump text into the
		-- To field or overwrite the recipients.
		if clipReady then
			set focusResult to mmdFocusMessageBody(focusSubject)
			mmdLog("focus result: " & focusResult)
			if focusResult is "ok" or focusResult is "ok-web" or focusResult is "ok-tab" then
				-- Reply: caret starts above Mail's quote — paste there and leave the
				-- quote intact. Never Cmd-A (that wiped the reply template).
				-- New draft: body is empty, paste fills it.
				tell application "System Events" to keystroke "v" using {command down}
				delay 0.6
				if usedReply then
					-- Blank line between our reply and the quoted original.
					tell application "System Events"
						keystroke return
						keystroke return
					end tell
					delay 0.2
				end if

				-- Do NOT test whether the content looks right here. Mail's AppleScript
				-- `content` only ever reports what was set through AppleScript, and
				-- stays empty after a paste even when the paste worked perfectly.
				set subjectIntact to true
				try
					tell application "Mail"
						if (subject of newMessage) is not focusSubject then set subjectIntact to false
					end tell
				end try

				if not subjectIntact then
					tell application "Mail"
						set subject of newMessage to focusSubject
					end tell
					-- For a new draft only, fall back to plain content. Never clobber a reply quote.
					if not usedReply then
						tell application "Mail" to set content of newMessage to theBody
						set end of mmdNotes to "The formatted text pasted into the wrong field, so the subject has been put back and the draft filled in as plain text."
					else
						set end of mmdNotes to "The formatted text may have missed the body; check the reply window (quoted original left intact)."
					end if
				end if
			else
				if not usedReply then
					tell application "Mail" to set content of newMessage to theBody
					set end of mmdNotes to "The formatted text could not be pasted, so the draft was filled in as plain text." & return & return & "Reason: " & focusResult
				else
					set end of mmdNotes to "Could not paste into the reply body (" & focusResult & "). Quoted original left intact — paste your text manually."
				end if
			end if
		end if

		-- New drafts: GUI Attach Files (AppleScript make new attachment is a no-op
		-- on current Mail — it returns OK and leaves mail attachments at 0).
		if (not usedReply) and ((count of foundFiles) > 0) then
			set focusResult to mmdFocusMessageBody(focusSubject)
			if focusResult is "ok" or focusResult is "ok-web" or focusResult is "ok-tab" then
				tell application "System Events"
					key code 125 using {command down}
					delay 0.15
					keystroke return
					delay 0.1
				end tell
			end if
			mmdAttachFilesToDraft(newMessage, foundFiles, focusSubject)
		end if
	end if

	mmdCheckAttachmentCount(newMessage, focusSubject, attachSpecs, foundFiles)
end mmdMakeDraft


-- Apply To/Cc/Bcc from the .md. Non-empty lists replace Mail's recipients for
-- that field (needed for threaded replies, where Mail fills recipients from
-- the original message).
on mmdApplyRecipients(newMessage, toList, ccList, bccList)
	tell application "Mail"
		tell newMessage
			if (count of toList) > 0 then
				try
					delete (every to recipient)
				end try
				repeat with addr in toList
					make new to recipient at end of to recipients ¬
						with properties {address:(addr as text)}
				end repeat
			end if
			if (count of ccList) > 0 then
				try
					delete (every cc recipient)
				end try
				repeat with addr in ccList
					make new cc recipient at end of cc recipients ¬
						with properties {address:(addr as text)}
				end repeat
			end if
			if (count of bccList) > 0 then
				try
					delete (every bcc recipient)
				end try
				repeat with addr in bccList
					make new bcc recipient at end of bcc recipients ¬
						with properties {address:(addr as text)}
				end repeat
			end if
		end tell
	end tell
	mmdLog("recipients: to=" & (count of toList) & " cc=" & (count of ccList) & " bcc=" & (count of bccList))
end mmdApplyRecipients


-- Reply + attachments via GUI Attach Files (does not wipe quote/body).
-- Order: our reply text → attachments → native cited quote.
on mmdReplyWithAttachments(newMessage, foundFiles, focusSubject, clipReady)
	mmdLog("reply+attach: paste body then GUI Attach Files")

	tell application "Mail" to activate
	delay 0.35

	if clipReady then
		set focusResult to mmdFocusMessageBody(focusSubject)
		mmdLog("reply+attach: focus " & focusResult)
		if focusResult is "ok" or focusResult is "ok-web" or focusResult is "ok-tab" then
			tell application "System Events"
				tell process "Mail" to set frontmost to true
				keystroke "v" using {command down}
				delay 0.55
				keystroke return
				keystroke return
				delay 0.2
			end tell
			mmdLog("reply+attach: pasted reply body above quote")
		else
			set end of my mmdNotes to "Could not focus the reply body (" & focusResult & "). Attachments were skipped so the quoted original stays intact."
			return
		end if
	else
		set end of my mmdNotes to "Reply body clipboard was empty; only the quoted original is in the draft."
	end if

	mmdAttachFilesToDraft(newMessage, foundFiles, focusSubject)
end mmdReplyWithAttachments


-- Modern Mail ignores AppleScript `make new attachment` (returns OK, count stays 0).
-- GUI Attach Files works only on the front compose window. Several drafts can
-- share "Re: …", so we retitle uniquely, attach every staged file in ONE
-- dialog (Go to Folder + Cmd-A), then restore the subject. Count via Message
-- Size: `mail attachments` is always 0 for GUI-attached files.
on mmdAttachFilesToDraft(newMessage, foundFiles, focusSubject)
	if (count of foundFiles) is 0 then return
	set realSubject to focusSubject
	try
		tell application "Mail" to set realSubject to (subject of newMessage) as text
	end try
	set tempSubject to "ME-att-" & (random number from 100000 to 999999)
	try
		tell application "Mail" to set subject of newMessage to tempSubject
	end try
	delay 0.4
	mmdRaiseCompose(tempSubject)
	set sizeBefore to 0
	repeat 12 times
		set sizeBefore to mmdMessageSizeBytes(tempSubject)
		if sizeBefore > 0 then exit repeat
		delay 0.2
	end repeat
	set expectedBytes to mmdFilesByteTotal(foundFiles)
	set landed to 0
	repeat with aFile in foundFiles
		set posixPath to POSIX path of aFile
		set beforeOne to mmdMessageSizeBytes(tempSubject)
		set okOne to mmdGUIAttachOneFile(posixPath, tempSubject)
		delay 0.45
		set afterOne to mmdMessageSizeBytes(tempSubject)
		if okOne then
			if afterOne > beforeOne or beforeOne = 0 then
				set landed to landed + 1
			else
				-- Small files may not change a rounded "1 MB" label.
				set landed to landed + 1
			end if
		end if
		mmdLog("attach one " & posixPath & " ok=" & okOne & " size " & beforeOne & "->" & afterOne)
	end repeat
	delay 0.4
	set sizeAfter to mmdMessageSizeBytes(tempSubject)
	set delta to sizeAfter - sizeBefore
	mmdLog("attach size before=" & sizeBefore & " after=" & sizeAfter & " delta=" & delta & " expected=" & expectedBytes & " landed=" & landed)
	set attached to landed
	if sizeBefore > 0 and expectedBytes > 0 and delta < 4000 and landed > 0 then
		-- GUI thought it succeeded but Message Size did not move.
		set attached to 0
	end if
	if sizeBefore > 0 and expectedBytes > 0 and delta >= (expectedBytes * 0.4) then
		set attached to count of foundFiles
	end if
	set my mmdAttachedCount to attached
	if attached < (count of foundFiles) then
		set end of mmdNotes to "Attach Files did not add every file (Message Size +" & delta & " bytes)."
	end if
	try
		tell application "Mail" to set subject of newMessage to realSubject
	end try
	delay 0.2
end mmdAttachFilesToDraft


on mmdRaiseCompose(winTitle)
	tell application "Mail" to activate
	delay 0.2
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			if exists window winTitle then
				try
					perform action "AXRaise" of window winTitle
				end try
			end if
		end tell
	end tell
	delay 0.15
end mmdRaiseCompose


on mmdWaitSheet(winTitle)
	repeat 15 times
		try
			tell application "System Events"
				tell process "Mail"
					if exists window winTitle then
						if (count of sheets of window winTitle) > 0 then return true
					end if
				end tell
			end tell
		end try
		delay 0.2
	end repeat
	return false
end mmdWaitSheet


on mmdSetGoToFolder(winTitle, posixPath)
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			if exists window winTitle then
				perform action "AXRaise" of window winTitle
			end if
			keystroke "g" using {command down, shift down}
		end tell
	end tell
	delay 0.7
	set typed to false
	tell application "System Events"
		tell process "Mail"
			if exists window winTitle then
				set w to window winTitle
				set goSheet to missing value
				try
					if (count of sheets of sheet 1 of w) > 0 then set goSheet to sheet 1 of sheet 1 of w
				end try
				if goSheet is missing value then
					try
						if (count of sheets of w) > 1 then set goSheet to sheet 2 of w
					end try
				end if
				if goSheet is not missing value then
					try
						set value of text field 1 of goSheet to posixPath
						set typed to true
					end try
					if not typed then
						try
							set value of combo box 1 of goSheet to posixPath
							set typed to true
						end try
					end if
				end if
			end if
			if not typed then
				keystroke "a" using {command down}
				delay 0.05
				keystroke posixPath
			end if
			delay 0.2
			keystroke return
		end tell
	end tell
	delay 0.8
end mmdSetGoToFolder


on mmdGUIAttachOneFile(posixPath, winTitle)
	mmdRaiseCompose(winTitle)
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			try
				click menu item "Attach Files…" of menu "File" of menu bar 1
			on error
				keystroke "a" using {shift down, command down}
			end try
		end tell
	end tell
	if not mmdWaitSheet(winTitle) then
		mmdLog("Attach Files sheet did not appear on " & winTitle)
		return false
	end if
	try
		mmdSetGoToFolder(winTitle, posixPath)
		tell application "System Events"
			tell process "Mail"
				set frontmost to true
				keystroke "a" using {command down}
				delay 0.25
				set clicked to false
				if exists window winTitle then
					try
						click button "Open" of sheet 1 of window winTitle
						set clicked to true
					end try
					if not clicked then
						try
							click button "Choose File" of sheet 1 of window winTitle
							set clicked to true
						end try
					end if
					if not clicked then
						try
							click button "Choose" of sheet 1 of window winTitle
							set clicked to true
						end try
					end if
				end if
				if not clicked then keystroke return
			end tell
		end tell
	on error errMsg
		mmdLog("Attach Files navigation failed: " & errMsg)
		try
			tell application "System Events" to key code 53
		end try
		return false
	end try
	delay 0.8
	try
		tell application "System Events"
			tell process "Mail"
				if exists window winTitle then
					if (count of sheets of window winTitle) > 0 then
						key code 53
						delay 0.2
						mmdLog("Attach Files sheet still open after confirm")
						return false
					end if
				end if
			end tell
		end tell
	end try
	return true
end mmdGUIAttachOneFile


on mmdStageDirectory(foundFiles)
	set tmpDir to do shell script "/usr/bin/mktemp -d -t mailexporter-attach"
	set i to 1
	repeat with aFile in foundFiles
		set src to POSIX path of aFile
		set base to mmdFileNameOfPOSIX(src)
		set dest to tmpDir & "/" & i & "-" & base
		do shell script "/bin/cp -p " & quoted form of src & " " & quoted form of dest
		set i to i + 1
	end repeat
	mmdLog("staged attachments in " & tmpDir)
	return tmpDir
end mmdStageDirectory

on mmdFileNameOfPOSIX(posixPath)
	set lastSlash to 0
	repeat with i from (length of posixPath) to 1 by -1
		if character i of posixPath is "/" then
			set lastSlash to i
			exit repeat
		end if
	end repeat
	if lastSlash is 0 then return posixPath
	if lastSlash is (length of posixPath) then return posixPath
	return text (lastSlash + 1) thru -1 of posixPath
end mmdFileNameOfPOSIX

on mmdFilesByteTotal(foundFiles)
	set total to 0
	repeat with aFile in foundFiles
		try
			set sz to do shell script "/usr/bin/stat -f %z " & quoted form of (POSIX path of aFile)
			set total to total + (sz as integer)
		end try
	end repeat
	return total
end mmdFilesByteTotal

on mmdParseSizeToBytes(raw)
	set s to mmdTrim(raw)
	if s is "" then return 0
	set factor to 1
	set numText to s
	ignoring case
		if s ends with "bytes" then
			set numText to mmdTrim(text 1 thru -6 of s)
			set factor to 1
		else if s ends with "GB" then
			set numText to mmdTrim(text 1 thru -3 of s)
			set factor to 1000000000
		else if s ends with "MB" then
			set numText to mmdTrim(text 1 thru -3 of s)
			set factor to 1000000
		else if s ends with "KB" then
			set numText to mmdTrim(text 1 thru -3 of s)
			set factor to 1000
		else if s ends with "B" then
			set numText to mmdTrim(text 1 thru -2 of s)
			set factor to 1
		end if
	end ignoring
	try
		return ((numText as real) * factor) as integer
	end try
	return 0
end mmdParseSizeToBytes

on mmdMessageSizeBytes(winTitle)
	if winTitle is "" then return 0
	try
		tell application "System Events"
			tell process "Mail"
				if not (exists window winTitle) then return 0
				set prev to ""
				repeat with e in UI elements of window winTitle
					set nm to ""
					try
						set nm to name of e as text
					end try
					if nm is "" then
						try
							set nm to description of e as text
						end try
					end if
					if prev is "Message Size:" then
						return my mmdParseSizeToBytes(nm)
					end if
					set prev to nm
				end repeat
			end tell
		end tell
	end try
	return 0
end mmdMessageSizeBytes

on mmdCheckAttachmentCount(newMessage, focusSubject, attachSpecs, foundFiles)
	set requestedCount to count of attachSpecs
	if requestedCount is 0 then return
	set attachedCount to mmdAttachedCount
	if attachedCount < 0 then
		set attachedCount to 0
		if (count of foundFiles) is 0 then
			set attachedCount to 0
		end if
	end if
	set end of mmdNotes to "attached " & attachedCount & " of " & requestedCount
	mmdLog("attach count: " & attachedCount & " of " & requestedCount)
	if attachedCount is not requestedCount then set mmdAttachMismatch to true
end mmdCheckAttachmentCount


-- Normalize Message-ID to include angle brackets (Mail usually stores them).
on mmdNormalizeMessageID(rawID)
	set s to mmdTrim(rawID)
	if s is "" then return ""
	if character 1 of s is not "<" then set s to "<" & s
	if character -1 of s is not ">" then set s to s & ">"
	return s
end mmdNormalizeMessageID


-- Find a Mail message by RFC Message-ID.
-- Mail stores message id WITHOUT angle brackets; we try both forms.
-- Prefer top-level All Inboxes / All Sent, then every account mailbox.
on mmdFindMessageByID(rawID)
	set needle to mmdNormalizeMessageID(rawID)
	if needle is "" then return missing value
	set bare to text 2 thru -2 of needle
	mmdLog("find message-id: " & needle & " / bare: " & bare)

	tell application "Mail"
		-- Fast path: inbox / sent with contains (exact `is` is flaky on some accounts)
		set boxes to {}
		try
			set end of boxes to inbox
		end try
		try
			set end of boxes to sent mailbox
		end try

		repeat with mbox in boxes
			try
				set hits to (every message of mbox whose message id contains bare)
				if (count of hits) > 0 then return item 1 of hits
			end try
			try
				set hits to (every message of mbox whose message id is needle)
				if (count of hits) > 0 then return item 1 of hits
			end try
			try
				set hits to (every message of mbox whose message id is bare)
				if (count of hits) > 0 then return item 1 of hits
			end try
		end repeat

		-- Slower: scan account mailboxes (still prefer contains)
		repeat with acct in every account
			try
				repeat with mbox in (every mailbox of acct)
					try
						set hits to (every message of mbox whose message id contains bare)
						if (count of hits) > 0 then return item 1 of hits
					end try
				end repeat
			end try
		end repeat
	end tell
	return missing value
end mmdFindMessageByID


-- Tell the user about anything that went wrong. The draft is always made, so
-- these are things to fix by hand rather than failures.
on mmdReportProblems()
	set theText to mmdResultText()
	if theText is "OK" then return

	display dialog "The draft was created, but:" & return & return & theText ¬
		buttons {"OK"} default button 1 ¬
		with title "Make Mail Draft" with icon caution
end mmdReportProblems


-- ---------------------------------------------------------------------------
-- Getting formatted text into Mail
-- ---------------------------------------------------------------------------

-- Convert HTML and put it on the clipboard as public.html only.
-- Do not also offer RTF: Mail prefers RTF and mangles numbered lists.
on mmdPutHTMLOnClipboard(theHTML)
	try
		set tmpDir to do shell script "/usr/bin/mktemp -d -t makemaildraft"
		set htmlPath to tmpDir & "/body.html"
		mmdWriteTextFile(htmlPath, theHTML)
		set jxa to mmdClipboardScriptPath()
		if jxa is "" then error "PutHTMLOnClipboard.js not found"
		do shell script "/usr/bin/osascript -l JavaScript " & quoted form of jxa & " " & ¬
			quoted form of htmlPath
		do shell script "/bin/rm -rf " & quoted form of tmpDir
		return true
	on error errMsg
		set end of mmdNotes to "Could not prepare the formatted text (" & errMsg & ¬
			"), so the draft was filled in as plain text."
		return false
	end try
end mmdPutHTMLOnClipboard


on mmdClipboardScriptPath()
	set here to POSIX path of (path to me)
	-- path to me is the .applescript when run via osascript
	set dir to mmdParentFolder(here)
	set candidate to dir & "PutHTMLOnClipboard.js"
	try
		do shell script "/bin/test -f " & quoted form of candidate
		return candidate
	end try
	return ""
end mmdClipboardScriptPath


on mmdLog(theText)
	set mmdLogText to mmdLogText & theText & return
end mmdLog


on mmdWriteLog()
	-- Intentionally empty: a /tmp log leaked subjects and attach paths.
end mmdWriteLog


on mmdWriteTextFile(posixPath, theText)
	set fRef to open for access (POSIX file posixPath) with write permission
	try
		set eof fRef to 0
		write theText to fRef as «class utf8»
		close access fRef
	on error errMsg
		try
			close access fRef
		end try
		error errMsg
	end try
end mmdWriteTextFile


-- Put the insertion point in the message body.
--
-- There is no way to focus the body directly: as of macOS 26, Mail's compose
-- window exposes NO text area to accessibility at all — searching the whole
-- window for one finds zero. The header fields are all there, though, and the
-- Subject field is the last of them, so focusing that and pressing Tab once
-- lands in the body.
--
-- This matters more than it sounds. A new compose window starts with the caret
-- in the TO field, so pasting without doing this would put the entire email
-- into the recipients. Everything below refuses rather than guesses:
--
--   * the compose window is found by name, which Mail sets to the subject, so
--     dropping several files at once cannot paste into the previous draft
--   * the field we are about to Tab out of must actually contain the subject
--
-- If either check fails we return false and the caller falls back to plain
-- text, which is the old behaviour and always safe.
-- Returns the text "ok", or a description of what stopped it. The caller shows
-- that description, so a failure says which step gave up rather than leaving
-- you guessing between a permission problem and a changed window layout.
on mmdFocusMessageBody(expectedTitle)
	-- No subject means no way to identify the window. Not worth the risk.
	if expectedTitle is "" then
		return "the email has no Subject:, so the compose window cannot be identified"
	end if

	-- Ask for something that needs Accessibility, to separate "not allowed" from
	-- "allowed, but the window was not what we expected".
	try
		tell application "System Events" to tell process "Mail" to get (count of windows)
	on error errMsg
		return "this app does not have Accessibility permission (" & errMsg & ")"
	end try

	try
		tell application "System Events"
			tell process "Mail"
				set frontmost to true

				-- Wait for the compose window to appear, up to ~3 seconds.
				set theWindow to missing value
				repeat 30 times
					if (exists window expectedTitle) then
						set theWindow to window expectedTitle
						exit repeat
					end if
					delay 0.1
				end repeat
				if theWindow is missing value then
					return "no compose window titled \"" & expectedTitle & "\" appeared"
				end if

				-- Prefer the real message body (AXWebArea). Subject+Tab can land on
				-- an attachment chip once files are present, which made Cmd-V /
				-- verification select dog-1.jpg instead of the body.
				set bodyArea to missing value
				try
					repeat with e in (entire contents of theWindow)
						try
							if (role of e as text) is "AXWebArea" then
								set d to ""
								try
									set d to description of e as text
								end try
								if d is "message body" then
									set bodyArea to e
									exit repeat
								end if
							end if
						end try
					end repeat
				end try

				if bodyArea is not missing value then
					try
						set focused of bodyArea to true
					end try
					delay 0.2
					set bodyPos to position of bodyArea
					-- Click near the top of the body (where reply caret / our paste belong).
					click at {(item 1 of bodyPos) + 60, (item 2 of bodyPos) + 28}
					delay 0.25
					return "ok-web"
				end if

				-- Fallback: Subject field is last of the header fields; Tab once → body.
				set subjectField to last text field of theWindow
				set fieldValue to ((value of subjectField) as text)
				if fieldValue is not expectedTitle then
					return "the last text field held \"" & fieldValue & "\" rather than the subject"
				end if

				set focused of subjectField to true
				delay 0.3
				keystroke tab
				delay 0.3
				return "ok-tab"
			end tell
		end tell
	on error errMsg
		return "failed while reaching for the body (" & errMsg & ")"
	end try
	return "gave up for an unknown reason"
end mmdFocusMessageBody


-- ---------------------------------------------------------------------------
-- Markdown to HTML
-- ---------------------------------------------------------------------------

on mmdMarkdownToHTML(mdText)
	set theLines to paragraphs of mdText
	set lineCount to count of theLines
	set htmlParts to {}
	set i to 1

	repeat while i ≤ lineCount
		set thisLine to mmdTrim((item i of theLines) as text)

		if thisLine is "" then
			set i to i + 1

		else if thisLine is "---" or thisLine is "***" or thisLine is "___" then
			set end of htmlParts to "<hr>"
			set i to i + 1

		else if mmdStartsWith(thisLine, "### ") then
			set end of htmlParts to "<p style=\"" & mmdBodyStyle & "\"><b>" & mmdInline(mmdDropChars(thisLine, 4)) & "</b></p>"
			set i to i + 1

		else if mmdStartsWith(thisLine, "## ") then
			set end of htmlParts to "<p style=\"font-size:15px\"><b>" & ¬
				mmdInline(mmdDropChars(thisLine, 3)) & "</b></p>"
			set i to i + 1

		else if mmdStartsWith(thisLine, "# ") then
			set end of htmlParts to "<p style=\"font-size:17px\"><b>" & ¬
				mmdInline(mmdDropChars(thisLine, 2)) & "</b></p>"
			set i to i + 1

		else if mmdBulletContent(thisLine) is not missing value then
			set listItems to {}
			repeat while i ≤ lineCount
				set rawLine to mmdTrim((item i of theLines) as text)
				if rawLine is "" then
					if mmdNextNonBlankIsBullet(theLines, lineCount, i + 1) then
						set i to i + 1
					else
						exit repeat
					end if
				else
					set itemText to mmdBulletContent(rawLine)
					if itemText is missing value then exit repeat
					set end of listItems to "<li>" & mmdInline(itemText) & "</li>"
					set i to i + 1
				end if
			end repeat
			set end of htmlParts to "<ul style=\"" & mmdBodyStyle & "\">" & ¬
				mmdJoinPlain(listItems) & "</ul>"

		else if mmdNumberContent(thisLine) is not missing value then
			-- One <ol> even when Markdown has blank lines between items.
			set listItems to {}
			repeat while i ≤ lineCount
				set rawLine to mmdTrim((item i of theLines) as text)
				if rawLine is "" then
					if mmdNextNonBlankIsNumbered(theLines, lineCount, i + 1) then
						set i to i + 1
					else
						exit repeat
					end if
				else
					set itemText to mmdNumberContent(rawLine)
					if itemText is missing value then exit repeat
					set end of listItems to "<li>" & mmdInline(itemText) & "</li>"
					set i to i + 1
				end if
			end repeat
			set end of htmlParts to "<ol style=\"" & mmdBodyStyle & "\">" & ¬
				mmdJoinPlain(listItems) & "</ol>"

		else if mmdStartsWith(thisLine, "> ") then
			set quoteLines to {}
			repeat while i ≤ lineCount
				set t to mmdTrim((item i of theLines) as text)
				if not mmdStartsWith(t, "> ") then exit repeat
				set end of quoteLines to mmdInline(mmdDropChars(t, 2))
				set i to i + 1
			end repeat
			-- An explicit margin, not <blockquote>: textutil ignores the tag
			-- completely and the quote comes out looking like your own words.
			set end of htmlParts to "<p style=\"" & mmdBodyStyle & ";margin-left:30px\">" & ¬
				mmdJoinWith(quoteLines, "<br>") & "</p>"

		else
			-- An ordinary paragraph. Runs until a blank line or the start of
			-- some other block. Line breaks inside it are kept, so a signature
			-- written across two lines stays across two lines.
			set paraLines to {}
			repeat while i ≤ lineCount
				set t to mmdTrim((item i of theLines) as text)
				if t is "" then exit repeat
				if mmdIsBlockStart(t) then exit repeat
				set end of paraLines to mmdInline(t)
				set i to i + 1
			end repeat
			set end of htmlParts to "<p style=\"" & mmdBodyStyle & "\">" & ¬
				mmdJoinWith(paraLines, "<br>") & "</p>"
		end if
	end repeat

	return "<html><head><meta charset=\"utf-8\"></head><body style=\"" & ¬
		mmdBodyStyle & "\">" & mmdJoinPlain(htmlParts) & "</body></html>"
end mmdMarkdownToHTML


-- Would this line begin a block of its own? Used to end a paragraph.
on mmdIsBlockStart(aLine)
	if aLine is "---" or aLine is "***" or aLine is "___" then return true
	if mmdStartsWith(aLine, "# ") then return true
	if mmdStartsWith(aLine, "## ") then return true
	if mmdStartsWith(aLine, "### ") then return true
	if mmdStartsWith(aLine, "> ") then return true
	if mmdBulletContent(aLine) is not missing value then return true
	if mmdNumberContent(aLine) is not missing value then return true
	return false
end mmdIsBlockStart


-- "- thing" becomes "thing". Returns missing value if it isn't a bullet.
-- Indented sub-bullets have already been trimmed, so they join the same list
-- rather than nesting.
on mmdBulletContent(aLine)
	repeat with aMarker in {"- ", "* ", "+ "}
		if mmdStartsWith(aLine, aMarker as text) then return mmdDropChars(aLine, 2)
	end repeat
	return missing value
end mmdBulletContent


on mmdNextNonBlankIsBullet(theLines, lineCount, startAt)
	repeat with j from startAt to lineCount
		set peek to mmdTrim((item j of theLines) as text)
		if peek is not "" then return (mmdBulletContent(peek) is not missing value)
	end repeat
	return false
end mmdNextNonBlankIsBullet


on mmdNextNonBlankIsNumbered(theLines, lineCount, startAt)
	repeat with j from startAt to lineCount
		set peek to mmdTrim((item j of theLines) as text)
		if peek is not "" then return (mmdNumberContent(peek) is not missing value)
	end repeat
	return false
end mmdNextNonBlankIsNumbered


-- "3. thing" becomes "thing". Returns missing value if it isn't numbered.
on mmdNumberContent(aLine)
	set digitCount to 0
	repeat with i from 1 to (length of aLine)
		if (character i of aLine) is in "0123456789" then
			set digitCount to digitCount + 1
		else
			exit repeat
		end if
	end repeat
	if digitCount is 0 then return missing value
	if (length of aLine) < (digitCount + 2) then return missing value
	if (text (digitCount + 1) thru (digitCount + 2) of aLine) is not ". " then return missing value
	return mmdDropChars(aLine, digitCount + 2)
end mmdNumberContent


-- Inline markup, on one line of text. Escaping happens first so that any < or
-- & already in the text cannot become a tag, and the tags we add afterwards
-- are the only real markup in the result.
on mmdInline(aLine)
	set s to mmdEscapeHTML(aLine)
	set s to mmdConvertLinks(s)
	set s to mmdWrapPairs(s, "**", "<b>", "</b>")
	set s to mmdWrapPairs(s, "*", "<i>", "</i>")
	return s
end mmdInline


on mmdEscapeHTML(aLine)
	set s to mmdReplaceText(aLine, "&", "&amp;")
	set s to mmdReplaceText(s, "<", "&lt;")
	set s to mmdReplaceText(s, ">", "&gt;")
	set s to mmdReplaceText(s, "\"", "&quot;")
	return s
end mmdEscapeHTML


-- [text](url) becomes a real link. Anything that isn't a complete, well-formed
-- link is left exactly as the author typed it.
on mmdConvertLinks(aLine)
	set outText to ""
	set restText to aLine

	repeat
		set p1 to offset of "[" in restText
		if p1 is 0 then exit repeat

		set headPart to ""
		if p1 > 1 then set headPart to text 1 thru (p1 - 1) of restText
		if p1 ≥ (length of restText) then exit repeat
		set afterOpen to text (p1 + 1) thru -1 of restText

		set p2 to offset of "]" in afterOpen
		if p2 is 0 then exit repeat
		set linkText to ""
		if p2 > 1 then set linkText to text 1 thru (p2 - 1) of afterOpen
		if p2 ≥ (length of afterOpen) then exit repeat
		set afterClose to text (p2 + 1) thru -1 of afterOpen

		if (character 1 of afterClose) is not "(" then
			-- square brackets used as ordinary punctuation
			set outText to outText & headPart & "["
			set restText to afterOpen
		else
			set p3 to offset of ")" in afterClose
			if p3 is 0 then exit repeat
			set theURL to ""
			if p3 > 2 then set theURL to text 2 thru (p3 - 1) of afterClose
			-- Allow only safe URL schemes (block javascript:, data:, file:, …).
			set urlOK to false
			ignoring case
				if theURL starts with "https:" then set urlOK to true
				if theURL starts with "http:" then set urlOK to true
				if theURL starts with "mailto:" then set urlOK to true
			end ignoring
			if urlOK then
				set outText to outText & headPart & "<a href=\"" & theURL & "\">" & linkText & "</a>"
			else
				set outText to outText & headPart & linkText
			end if
			if p3 ≥ (length of afterClose) then
				set restText to ""
				exit repeat
			end if
			set restText to text (p3 + 1) thru -1 of afterClose
		end if
	end repeat

	return outText & restText
end mmdConvertLinks


-- Wrap matched pairs of a delimiter in tags: **x** becomes <b>x</b>.
-- An unmatched delimiter is left alone, so a lone asterisk stays an asterisk.
on mmdWrapPairs(aLine, theDelim, openTag, closeTag)
	set dLen to length of theDelim
	set outText to ""
	set restText to aLine

	repeat
		if (length of restText) < ((2 * dLen) + 1) then exit repeat

		set p1 to offset of theDelim in restText
		if p1 is 0 then exit repeat
		set headPart to ""
		if p1 > 1 then set headPart to text 1 thru (p1 - 1) of restText

		set tailStart to p1 + dLen
		if tailStart > (length of restText) then exit repeat
		set tailPart to text tailStart thru -1 of restText

		set p2 to offset of theDelim in tailPart
		if p2 is 0 then exit repeat

		-- Both delimiters must sit hard against the text they wrap, so
		-- "3 * 4 grid" and a stray asterisk stay as typed. Only *this* counts.
		set openHugs to (character 1 of tailPart) is not in {" ", tab}
		set closeHugs to false
		if p2 > 1 then set closeHugs to (character (p2 - 1) of tailPart) is not in {" ", tab}

		if not (openHugs and closeHugs) then
			set outText to outText & headPart & theDelim
			set restText to tailPart
		else
			set inner to text 1 thru (p2 - 1) of tailPart
			set outText to outText & headPart & openTag & inner & closeTag
			set afterStart to p2 + dLen
			if afterStart > (length of tailPart) then
				set restText to ""
				exit repeat
			end if
			set restText to text afterStart thru -1 of tailPart
		end if
	end repeat

	return outText & restText
end mmdWrapPairs


-- Swap every occurrence of one string for another.
on mmdReplaceText(aLine, findStr, replStr)
	set savedDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to findStr
	set theParts to text items of aLine
	set AppleScript's text item delimiters to replStr
	set outString to theParts as text
	set AppleScript's text item delimiters to savedDelims
	return outString
end mmdReplaceText


on mmdStartsWith(aLine, aPrefix)
	if (length of aLine) < (length of aPrefix) then return false
	return (text 1 thru (length of aPrefix) of aLine) is aPrefix
end mmdStartsWith


on mmdDropChars(aLine, howMany)
	if (length of aLine) ≤ howMany then return ""
	return text (howMany + 1) thru -1 of aLine
end mmdDropChars


-- ---------------------------------------------------------------------------
-- Everything below here is unchanged from the plain text version
-- ---------------------------------------------------------------------------

-- Turn an attachment path into a full POSIX path.
-- Prefer the project root (parent of Email/), then the .md folder.
on mmdProjectRoot(baseFolder)
	set p to baseFolder
	if p ends with "/" then set p to text 1 thru -2 of p
	if p ends with "/Drafts" then set p to text 1 thru -8 of p
	if p ends with "/Email" then set p to text 1 thru -7 of p
	if p does not end with "/" then set p to p & "/"
	return p
end mmdProjectRoot

on mmdPOSIXExists(posixPath)
	try
		POSIX file posixPath as alias
		return true
	on error
		return false
	end try
end mmdPOSIXExists

on mmdCanonicalPOSIX(posixPath)
	try
		return POSIX path of (POSIX file posixPath as alias)
	on error
		return posixPath
	end try
end mmdCanonicalPOSIX

on mmdPathInsideProject(posixPath, projectRoot)
	set resolved to mmdCanonicalPOSIX(posixPath)
	if resolved starts with projectRoot then return true
	return false
end mmdPathInsideProject

on mmdResolvePath(aPath, baseFolder)
	set aPath to mmdTrim(aPath)

	-- strip surrounding double quotes, for filenames containing commas
	if (length of aPath) > 1 and character 1 of aPath is "\"" and character -1 of aPath is "\"" then
		set aPath to text 2 thru -2 of aPath
	end if

	if aPath is "" then error "empty attachment path"
	if aPath starts with "~" then error "attachment path must stay inside the project: " & aPath

	set projectRoot to mmdProjectRoot(baseFolder)
	set candidate to ""
	if aPath starts with "/" then
		set candidate to aPath
	else
		set fromProject to projectRoot & aPath
		if mmdPOSIXExists(fromProject) then
			set candidate to fromProject
		else if baseFolder is not "" then
			set fromDrafts to baseFolder & aPath
			if mmdPOSIXExists(fromDrafts) then
				set candidate to fromDrafts
			end if
		end if
	end if
	if candidate is "" then error "not found: " & aPath
	if not mmdPathInsideProject(candidate, projectRoot) then
		error "attachment path must stay inside the project: " & aPath
	end if
	if mmdPOSIXExists(candidate) then return mmdCanonicalPOSIX(candidate)
	error "not found: " & aPath
end mmdResolvePath


-- The folder containing a POSIX file path, with a trailing slash.
on mmdParentFolder(aPath)
	set lastSlash to 0
	repeat with i from (length of aPath) to 1 by -1
		if character i of aPath is "/" then
			set lastSlash to i
			exit repeat
		end if
	end repeat
	if lastSlash is 0 then return ""
	return text 1 thru lastSlash of aPath
end mmdParentFolder


-- The bit before the first colon, e.g. "Subject" from "Subject: Hello".
-- Returns "" if the line has no colon, or if what precedes it contains a
-- space, which means it is body text rather than a header.
on mmdHeaderName(aLine)
	set colonPos to offset of ":" in aLine
	if colonPos is 0 then return ""
	if colonPos is 1 then return ""
	set nameOnly to text 1 thru (colonPos - 1) of aLine
	if nameOnly contains " " then return ""
	return nameOnly
end mmdHeaderName


-- Everything after the first colon, trimmed.
on mmdHeaderValue(aLine)
	set colonPos to offset of ":" in aLine
	if colonPos is 0 then return ""
	if (length of aLine) is colonPos then return ""
	return mmdTrim(text (colonPos + 1) thru -1 of aLine)
end mmdHeaderValue


-- Split on commas, but ignore commas inside double quotes.
on mmdSplitList(aString)
	set results to {}
	set current to ""
	set inQuotes to false

	repeat with i from 1 to (length of aString)
		set c to character i of aString
		if c is "\"" then
			set inQuotes to not inQuotes
			set current to current & c
		else if c is "," and inQuotes is false then
			set trimmed to mmdTrim(current)
			if trimmed is not "" then set end of results to trimmed
			set current to ""
		else
			set current to current & c
		end if
	end repeat

	set trimmed to mmdTrim(current)
	if trimmed is not "" then set end of results to trimmed
	return results
end mmdSplitList


on mmdSplitAddresses(aString)
	set results to {}
	repeat with aChunk in mmdSplitList(aString)
		set cleaned to mmdExtractAddress(aChunk as text)
		if cleaned is not "" then set end of results to cleaned
	end repeat
	return results
end mmdSplitAddresses


-- "Jane Doe <jane@example.com>" becomes "jane@example.com"
on mmdExtractAddress(aString)
	set openPos to offset of "<" in aString
	if openPos is 0 then return aString
	set closePos to offset of ">" in aString
	if closePos is 0 then return aString
	if closePos < openPos then return aString
	return mmdTrim(text (openPos + 1) thru (closePos - 1) of aString)
end mmdExtractAddress


on mmdTrim(aString)
	set padding to {" ", tab, return, linefeed}
	repeat while aString is not "" and (character 1 of aString) is in padding
		if (length of aString) is 1 then return ""
		set aString to text 2 thru -1 of aString
	end repeat
	repeat while aString is not "" and (character -1 of aString) is in padding
		if (length of aString) is 1 then return ""
		set aString to text 1 thru -2 of aString
	end repeat
	return aString
end mmdTrim


on mmdJoinLines(aList)
	return mmdJoinWith(aList, return)
end mmdJoinLines


on mmdJoinPlain(aList)
	return mmdJoinWith(aList, "")
end mmdJoinPlain


on mmdJoinWith(aList, theDelim)
	set savedDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to theDelim
	set outString to aList as text
	set AppleScript's text item delimiters to savedDelims
	return outString
end mmdJoinWith
