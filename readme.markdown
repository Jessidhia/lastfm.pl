Commands that access last.fm use the IRC nickname unless associated through .setuser.
Unlike IRC, all names are CASE SENSITIVE.

all commands have a prefix, this is set in irssi using /set lfmb_prefix <prefix>

Commands:
np [username]     - shows your currently playing song, or of another user if specified
compare u1 [u2]   - compares yourself with u1 (another user) if u2 isn't specified compares u1 with u2 if both are given.
setuser user      - associates the "user" last.fm username with your nickname. the two argument form is only available to the owner.
whois username    - given a last.fm username, return all nicknames that are associated to it.
deluser           - removes your last.fm association. the form with argument is only available to the owner.

to set the owner user you need to use /set lfmb_owner <owner nick>

Owner-only commands:
wp                - shows everyone's currently playing song
setuser nick user - associates the nick with the specified last.fm user
deluser nick      - removes the nick's association with his last.fm account
source            - shows the source repo for the bot


Inline commands:
You use inline commands like this.
<botnick>:<command>(:<arg>)

currently only np works. 
