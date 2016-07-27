My IRC client
=============

[![Build Status](https://secure.travis-ci.org/glguy/irc-core.svg)](http://travis-ci.org/glguy/irc-core)

![](https://raw.githubusercontent.com/wiki/glguy/irc-core/images/screenshot.png)

Library
=======

This package is split into a generic IRC modeling library and a VTY-base text client using that library.

Client Features
===============

* Subsequent joins and parts fold into one line and do not scroll chat messages off the screen
* Ignore support that folds ignored messages into the joins and parts. Toggle it off to see previously hidden messages
* Detailed view to see all the messages in a channel in full detail with hostmask and timestamp (F2)
* Nick tab completion
* SASL authentication
* New message notification
* Customizable mention filter (looks for your nick plus extra search terms)
* View ban, quiet, invex, and exception lists
* Support for rendering/inputing colors and formatting
* Haskell source code highlighting (/hs)
* Write your modifications in Haskell!
* Chanserv automation (automatically requests op from chanserv for privileged commands), automatically deop after 5 minutes of not performing privileged commands.
* Command syntax highlighting with hints.
* Each user's nick is assigned a consistent color, when a user's nick is rendered in a chat message it uses that same color.
* Support for /STATUSMSG/ messages
* Togglable support for merged view of all joined channels (F5).
* Run commands upon connection

TLS
===

I've added TLS support. You can enable it with the `-t` flag. Note that Freenode (and other networks) will allow you to authenticate to NickServ via a client certificate. This is configurable via `--tls-client-cert`.

I use the `x509-store` for decoding certificates and private key files. This library seems to support PEM formatted files and does not seem to support encrypted private key files. If the key and certificate are both contained in the certificate file the private key command line argument is unnecessary.

[Identifying with CERTFP](https://freenode.net/certfp/)

Startup
=======

```
glirc <options> SERVER
  -c FILENAME  --config=FILENAME       Configuration file path (default ~/.glirc/config)
  -p PORT      --port=PORT             IRC Server Port
  -n NICK      --nick=NICK             Nickname
  -u USER      --user=USER             Username
  -r REAL      --real=REAL             Real Name
               --sasl-user=USER        SASL username
  -d FILE      --debug=FILE            Debug log filename
  -i USERINFO  --userinfo=USERINFO     CTCP USERINFO Response
  -t           --tls                   Enable TLS
               --tls-client-cert=PATH  Path to PEM encoded client certificate
               --tls-client-key=PATH   Path to PEM encoded client key
               --tls-insecure          Disable server certificate verification
  -h           --help                  Show help

Environment variables
IRCPASSWORD=<your irc password>
SASLPASSWORD=<your sasl password>
```

Configuration file
=================

A configuration file can currently be used to provide some default values instead of
using command line arguments. If any value is missing the default will be used.

Learn more about this file format at [config-value](http://hackage.haskell.org/package/config-value)

```
-- Optional file to dump raw server messages
debug-file: "debug.txt"
download-dir: "~/downloads"

-- Defaults used when not specified on command line
defaults:
  port:            6667
  nick:            "yournick"
  username:        "yourusername"
  realname:        "Your real name"
  password:        "IRC server password"
  sasl-username:   "sasl_username"
  sasl-password:   "sasl_password"
  userinfo:        "user info string"
  tls:             yes -- or: no
  tls-client-cert: "/path/to/cert.pem"
  tls-client-key:  "/path/to/cert.key"

-- Override the defaults when connecting to specific servers
servers:
  * hostname:      "chat.freenode.net"
    sasl-username: "someuser"
    sasl-password: "somepass"
    socks-host:    "socks5.example.com"
    socks-port:    8080 -- defaults to 1080

  * hostname:      "example.com"
    port:          7000
    connect-cmds:
      * "JOIN #favoritechannel,#otherchannel"
      * "PRIVMSG mybot another command"

    -- Specify additional certificates beyond the system CAs
    server-certificates:
      * "/path/to/extra/certificate.pem"

```

Commands
========

* `/exit` - *Exit!*

* `/akb <nick> <message>` - Auto-kickban: Request ops from chanserv if needed, ban by accountname if known, hostname otherwise, kick with message
* `/bans` - Show known bans for current channel. Note: Request bans list with `/quote mode <channel> +b`
* `/channel <channel>` - switch to a user message window
* `/channelinfo` - Show information for the current channel
* `/ctcp <command> <params>` - Send CTCP command to current window
* `/clear` - Clear all messages for the current channel
* `/help <topic>` - Request help from the server
* `/hs <haskell source code>` - Send syntax highlighted source code as a message to the current channel
* `/ignore <nick>` - Toggle ignoring a user by nickname.
* `/join <channel>` - join a new channel (optional key argument)
* `/kick <nick> <msg>` - Kick a user from the current channel
* `/masks <mode>` - Show the bans (b), quiets (q), invex (I), or ban exemptions (e) for a channel. The list must be requested as above.
* `/me <message>` - send an action to the current channel
* `/mode <mode> <arguments>` - Set modes on the current channel
* `/msg <nick> <message>` - send a private message
* `/nick <nick>` - Change your nickname
* `/notice <nick> <message>` - send a notice message
* `/op <nicks>` - Op nicks in the channel, self when no nicks given
* `/deop <nicks>` - Deop nicks in the channel, self when no nicks given
* `/voice <nicks>` - Voice nicks in the channel, self when no nicks given
* `/devoice <nicks>` - Devoice nicks in the channel, self when no nicks given
* `/part <message>` - part the current channel with the given message
* `/query <nick>` - switch to a user message window
* `/quote <raw client command>` - send a client command verbatim
* `/remove <nick> <msg>` - Force a user to part from the current channel
* `/server` - switch to the server message window
* `/topic <topic>` - Change the topic for the current channel
* `/umode <mode>` - Set modes on yourself
* `/window <number>` - Jump to a window by index
* `/whois <nick>` - Query the server for information about a user
* `/whowas <nick>` - Query the server for information about a user who recently disconnected.
* `/stats <letter>` - Request server stat information, try `/help stats` on Freenode first.
* `/admin` - Request some basic admin contact information
* `/away <message>` - Toggle current away status
* `/time` - Request server time
* `/oper` - Enter your OPER credentials
* `/accept` - Add user to the "accept list", try `/help accept` on Freenode
* `/unaccept` - Remove a user from the "accept list"
* `/acceptlist` - List users on accept lists
* `/knock` - Request an /invite/ to a restricted channel
* `/invite <nick>` - Invite the given user to the current channel
* `/reconnect` - Reconnect to the current server
* `/ping` - Send ping to upload current roundtrip time
* `/ping <msg>` - Send manually specified ping message

Filters

* `/filter` - Filter chat messages by space-delimited set of nicknames
* `/grep` - Filter chat messages using a regular expression on the message

DCC commands

* `/transfers` - Show the DCC Offers and the ongoing progress
* `/dcc accept` - On the sender window starts the download
* `/dcc cancel` - as above but drops the offer and informs the sender with xdcc cancel

Keyboard Shortcuts
==================

* `ESC` quit
* `^N` next channel
* `^P` previous channel
* `M-#` jump to window
* `M-A` jump to activity
* `^A` beginning of line
* `^E` end of line
* `^K` delete to end
* `^U` delete to beginning
* `^D` delete at cursor
* `^W` delete word
* `^Y` paste from yank buffer
* `M-F` forward word
* `M-B` backward word
* `TAB` nickname completion
* `F2` toggle detailed view
* `F3` toggle timestamps
* `F4` toggle compressed metadata
* `F5` toggle all channel view
* `Page Up` scroll up
* `Page Down` scroll down
* `^B` bold
* `^C` color
* `^V` reverse video
* `^_` underline
* `^]` italic
* `^O` reset formatting
