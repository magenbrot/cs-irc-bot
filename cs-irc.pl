#!/usr/bin/perl -w

###############################################################################
# Counterstrike to IRC Bot
#
# Shows a Counterstrike-Game live on IRC (and much more)
#
# (2001) magenbrot
#
# Required modules/programs
#
# - strict-module =)
# - KKrcon
# - POE;
# - POE::Component::IRC;
# - IO::Socket
# - POSIX
# - Time::Local
# - Getopt::Long
# - Net::hostent
# - LWP::UserAgent
# - HTTP::Request
# - HTML::HeadParser
# - qstat (external program)
#
#
# ToDo-List
#
# - Optimize color-usage in IRC
# - Multi-Channel capability
# - Game statistics
# - say something on all channels the bot is on (only for authed admin)
# - maybe build a threading PerlBot, to serve more then one user a time (if possible)
# - quotefunktionen: addquote, quote, delquote - vgl. #nixblicka
# - reconnect to IRC after beeing disconnected
# - some Events in CS are not displayed (ie. Target bombed)
#
#
# Known bugs (note: for this is a first-time release there may be a plenty of bugs I don't know of)
#
# - none =)
#
#
# Features
#
# - forwarding events from an CS-server to IRC
# - forwarding public- and team-chat from the CS-server to IRC (optional, only for authed admin)
# - can authenticate himself with the Q from quakenet-IRC (optional)
# - rejoin channel after being kicked (optional)
# - can query the default- or any other hl-cs server
# - display server-rules
# - display server statistics (RCON status command)
# - capable to work behind a NAT-Firewall (the UDP-receive port must be correctly configured on the firewall)
# - can show fortunes on IRC (man fortune)
# - can be invited to other channels
# - can display current server-password (only for authed admin)
# - can change the map on server (only for authed admin)
# - tries to reconnect to IRC received the disconnected event
# - can be forced to reconnect to the hl-cs server (only for authed admin)
# - automatically gives +v to people joining a channel the bot is on (optional)
# - join other channels via /msg (only for authed admin) (!cjoin)
# - Admin-Auth
# - script_send: on request from a IRC-User the sources (gzipped) of the bot will be send to him via DCC
# - changes of servervariables are shown in IRC
# - !announce #channel (announces the watched game in other channels)
#
#
# Changes:
# v0.1 - the beginning
# v0.2 - complete rewrite of the bot, implemented POE-model
# v0.3 - outsourced the bot-configuration and admin-configuration
# v0.4 - bugfixing
#
#
# Greetings and Thanks to:
# Ian Cass <ian.cass@knowledge.com> for the callback {} function
# my clan independent][Lords <http://www.independent-lords.de>
#
###############################################################################

###############################################################################
# Load modules
###############################################################################

use strict;
use POE;
use POE::Component::IRC;
use IO::Socket;
use POSIX;
use Time::Local;
use Getopt::Long;
use Net::hostent;
use KKrcon;

###############################################################################
# Loading current configuration
###############################################################################

my %config = ();
my $debug = 1;
my %irc_name;
my %irc_admins = ();
my %irc_authed = ();
my @irc_quotes = ();

&LoadConfiguration;

my $version = "v0.4";

my $irc_Q_name = "Q\@CServe.quakenet.org";
my $irc_Q_msg = "AUTH $config{irc_Q_username} $config{irc_Q_password}";
my $irc_Q_success = 0;
my $irc_fortune_tmp1 = 0;
my $irc_fortune_tmp2 = time();

my $inet_ip = "";
my $inet_listen_ip = "";

my $hl_type = "new";
my $hl_rcon = "";
my $hl_mapchange = 0;
my $hl_connected = 0;
my $hl_result="";

###############################################################################
# don't edit anything below this line unless you know what you're doing
###############################################################################

# Start with empty stats
my %teams = ();
my %hash_kills = ();
my %hash_deaths = ();
my $timer = 0;
my $timer_status = 0;
my $player1 = "";
my $player2 = "";
my $color = "";
my $weapon = "";

###############################################################################
# Mainprogram
###############################################################################

$| = 1;
Getopt::Long::Configure ("bundling");

print ("INET - Getting public IP... ") if $debug;
$inet_ip = &get_ip();
if ($inet_ip =~ (/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/) && ($1 <= 255) && ($2 <= 255) && ($3 <= 255) && ($4 <= 255)) {
  print ("done: $inet_ip\n") if $debug;
}
else {
  die ("No valid IP received: $inet_ip !\n");
}

if ($config{inet_masqued}) {
  $inet_listen_ip = $config{inet_local_ip};
}
else {
  $inet_listen_ip = $inet_ip;
}

POE::Session->create
  ( inline_states =>
    { _start          => \&udp_server_start,
      _stop           => \&udp_server_stop,
      select_read     => \&udp_server_receive,
      socket_made     => \&udp_server_socket,
      socket_error    => \&udp_server_error,
    },
    args => [ $config{inet_listen_port} ],
    options => { Debug => 0 },
  );
print ("INET - UDP Port opened OK\n") if $debug;

# Connect to the HL-server
if ($config{hl_connect}) {
  &server_connect;
}

POE::Component::IRC->new($config{irc_nick}, trace => undef ) || die ("IRC - Can't instantiate new IRC component for \"$config{irc_nick}\"!\n");

POE::Session->new( 'main' => [qw(
  _start
  _stop
  _default
  irc_ctcp_version
  irc_ctcp_ping
  irc_ctcp_time
  irc_ctcp_source
  irc_ctcp_finger
  irc_dcc_done
  irc_dcc_error
  irc_disconnected
  irc_socketerr
  irc_error
  irc_join
  irc_nick
  irc_public
  irc_msg
  irc_invite
  irc_notice
  irc_part
  irc_quit
  irc_kick
  irc_001)] );

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel, $session) = @_[KERNEL, SESSION];
  # $session->option( trace => 1 );
  
  $kernel->alias_set('control');

  $irc_name{ $kernel->alias_resolve($config{irc_nick}) } = $config{irc_nick};
  $kernel->call($config{irc_nick}, 'register', 'all');

  print ("IRC - _start - $config{irc_nick} is connecting to $config{irc_server}...\n") if $debug;
  $kernel->call( $config{irc_nick}, 'connect', {
    Debug    => 0,
    Nick     => $config{irc_nick},
	  Server   => $config{irc_server},
	  Port     => $config{irc_port},
	  Username => $config{irc_uname},
	  Ircname  => $config{irc_name}, 
  } );
}

sub _stop {
  my ($kernel) = $_[KERNEL];

  $kernel->post('control', 'quit', $config{irc_quitmsg});

  print ("IRC - _stop - Disconnected all clients.\n") if $debug;
  print ("IRC - _stop - Control session stopping.\n") if $debug;
  $kernel->alias_remove('control');
}

sub _default {
  my ($state, $event, $args) = @_[STATE, ARG0, ARG1];

  $args ||= [];
  print ("IRC - $state -- $event @$args\n") if $debug;
}

sub irc_001 {
  my ($kernel, $sender) = @_[KERNEL, SENDER];

  print ("IRC - irc_001 - $irc_name{$sender} is connected.\n") if $debug;
  $kernel->post($sender, 'mode', $irc_name{$sender}, '+i' );
  $kernel->post($sender, 'away', "magenbrot meint: im westen nichts neues..." );
  $kernel->post($sender, 'join', $config{irc_channel1} );
  if($config{irc_Q_enabled} && ! $irc_Q_success) {
    print ("IRC - irc_001 - Trying to auth with Q: $irc_Q_name -> $irc_Q_msg\n") if $debug;
    $kernel->post( $sender, 'privmsg', $irc_Q_name, $irc_Q_msg);
  }
}
 
sub irc_join {
  my ($kernel, $sender, $who, $chan) = @_[KERNEL, SENDER, ARG0, ARG1];
  $who  =~ s/^(.*)!.*$/$1/;
  
  print ("IRC - irc_join - $who has joined $chan\n") if $debug;
  
  if ($who eq $config{irc_nick}) {
    my @qstat = `./qstat -hls $config{hl_ip}:$config{hl_port} -nh -raw \";\"`;
    my @erg = split(/;/, $qstat[0]);

    $kernel->post($sender, 'privmsg', $chan, $config{irc_joinmsg});
    $kernel->post($sender, 'privmsg', $chan, "$erg[2] ($erg[1]) $erg[5]/$erg[4] $erg[3] $erg[6]ms");
    if ((! $hl_connected) && (! $config{hl_connect})) {
      $kernel->post($sender, 'privmsg', $chan, "7Current settings say not to connect to the server...");
      $kernel->post($sender, 'privmsg', $chan, "7So I'm waiting here to serve u all...");
    }      
    elsif ((! $hl_connected) && ($config{hl_connect})) {
      $kernel->post($sender, 'privmsg', $chan, "4Attention: I could'nt connect to the server at startup.");
      $kernel->post($sender, 'privmsg', $chan, "4Please try a manual connect!");
    }
    else {
      $kernel->post($sender, 'privmsg', $chan, "3Connected successfully...");
    }
    
    # TESTSTATUS - Join more channels -> cs-irc.cfg
    if ($config{irc_channel2}) { $kernel->post($sender, 'join', $config{irc_channel2} ); }
    if ($config{irc_channel3}) { $kernel->post($sender, 'join', $config{irc_channel3} ); }
  }
  else {
    if ($config{irc_welcome}) {
      $kernel->post($sender, 'privmsg', $who, $config{irc_joinmsg});
      $kernel->post($sender, 'privmsg', $who, " ");
      $kernel->post($sender, 'privmsg', $who, "Welcome to channel $chan, $who");
      $kernel->post($sender, 'privmsg', $who, "Usage: !help");
    }
    if ($config{irc_autovoice}) {
      $kernel->post($sender, 'mode', $chan, "+v $who");
    }
  }
}

sub irc_disconnected {
  my ($sender, $irc_server) = @_[SENDER, ARG0];
  die ("IRC - irc_disconnected - $irc_name{$sender} lost connection to server $irc_server.\n");
}

sub irc_nick {
  my ($kernel, $sender, $who, $newnick) = @_[KERNEL, SENDER, ARG0, ARG1];
  
  print ("IRC - irc_nick - $who changed his nick to $newnick\n") if $debug;

  if (exists($irc_authed{$who})) {
    $irc_authed{$newnick} = 1;
    delete($irc_authed{$who});
  }  
}

sub irc_kick {
  my ($kernel, $sender, $bitch, $chan, $who, $reason) = @_[KERNEL, SENDER, ARG0 .. ARG3];
  $bitch  =~ s/^(.*)!.*$/$1/;

  if ($who eq $config{irc_nick} && $config{irc_rejoin}) {
    print ("IRC - on_kick - We were kicked by $bitch from $chan because: $reason!\n") if $debug;
    #sleep 5;
    $kernel->post($sender, 'join', $chan);
    $kernel->post($sender, 'privmsg', $chan, "$bitch, what r u doing!?");
  }
  elsif ($who eq $config{irc_nick} && ! $config{irc_rejoin}) {
    print ("IRC - on_kick - We were kicked by $bitch from $chan because: $reason!\n") if $debug;
  }
  else {
    print ("IRC - on_kick - $bitch has kicked $who from $chan because: $reason\n") if $debug;
  }
}

sub irc_error {
  my ($sender, $err) = @_[SENDER, ARG0];
  die ("A server error occurred to $irc_name{$sender}! $err\n");
}


sub irc_socketerr {
  my ($sender, $err) = @_[SENDER, ARG0];
  die ("$irc_name{$sender} couldn't connect to server: $err\n");
}

sub irc_notice {
  my ($kernel, $sender, $notice) = @_[KERNEL, SENDER, ARG2];
  if ($notice eq "AUTH'd successfully.") { $irc_Q_success = 1; }
  print ("IRC - irc_notice - $irc_name{$sender}: $notice\n") if $debug;
}

sub irc_public {
  my ($kernel, $sender, $who, $chan, $msg) = @_[KERNEL, SENDER, ARG0 .. ARG2];
  my @args=split(/ /, $msg);
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  print("IRC - irc_public: @$chan:<$who>: $msg\n") if $debug;
  
  if ($msg =~ /!qs/) {
    if ($args[1] eq "") {
      my @qstat = `./qstat -hls $config{hl_ip}:$config{hl_port} -nh -raw \";\"`;
      my @erg = split(/;/, $qstat[0]);
      $kernel->post($sender, 'privmsg', $chan, "$erg[2] ($erg[1]) $erg[5]/$erg[4] $erg[3] $erg[6]ms");
    }
    else {
      my @qstat = `./qstat -hls $args[1] -nh -raw \";\"`;
      my @erg = split(/;/, $qstat[0]);
      $kernel->post($sender, 'privmsg', $chan, "$erg[2] ($erg[1]) $erg[5]/$erg[4] $erg[3] $erg[6]ms");
    }
  }
  elsif ($msg =~ /!send_script/) {
    print ("SEND - $who requested the bot-script\n") if $debug;
    $kernel->post($sender, 'dcc', $who, 'send', 'cs-irc.tar.gz' );
  }
  elsif ($msg =~ /!weichei/) {
    $kernel->post($sender, 'ctcp', $chan, "ACTION", "sees that $who calls $args[1] a Weichei");
  }
  elsif ($msg =~ /!quote/ && $config{irc_quote}) {
    my $quote_nr;
    my $anzahl = @irc_quotes - 1;
    if ($args[1] eq "") {
      $quote_nr = sprintf("%.0f", rand $anzahl);
    }
    else {
      $quote_nr = sprintf("%.0f", $args[1] - 1);
    }
    my $quote_out = $irc_quotes[$quote_nr];
    print ("QUOTE - $who requested a quote\n") if $debug;
    $quote_nr++;
    $anzahl++;
    $kernel->post($sender, 'privmsg', $chan, "12i][Lords - Special ($quote_nr/$anzahl): $quote_out");
  }
  elsif ($msg =~ /!help/) {  
    &display_help($kernel, $sender, $who);
  }
  elsif ($msg =~ /!voice/) {
    print ("AUTH - $who got +v on @$chan\n") if $debug;
    $kernel->post($sender, 'mode', @$chan, "+v $who");
  }
  elsif ($msg =~ /!version/) {
    $kernel->post($sender, 'privmsg', $chan, "12,8     CS-to-IRC Bot - Version : $version from http://www.independent-lords.de     ");
  }
  elsif ($msg =~ /^!uptime$/i) {
    `uptime` =~ /.*up\s*(.*?),\s*(\d*):(\d*)/;
    $kernel->post($sender, 'privmsg', $chan, "I've been up $1, $2 hours and $3 minutes, honey :)");
  }
  elsif ($config{irc_fortune} && $msg =~ /!fortune/) { 
    my @fortune;
    $irc_fortune_tmp1 = time - $irc_fortune_tmp2;
    if ($irc_fortune_tmp1 > $config{irc_fortune_timeout}) {
      if ($args[1]) {
        @fortune = `fortune -s $args[1]`;
      }
      else {
        @fortune = `fortune -s -a`;
      }
      foreach my $item (@fortune) {
        $item =~ s/\t/     /g;
        $kernel->post($sender, 'privmsg', $chan, "$item");
        $irc_fortune_tmp2 = time;
      }
    }
  }

  # These commands are only available to authed admins

  elsif ($irc_authed{$who}) {
    if ($msg =~ /!op/) {
      if ($irc_authed{$who}) {
        print ("AUTH - $who becomes OP on @$chan\n") if $debug;
        $kernel->post($sender, 'mode', @$chan, "+o $who");
      }
      else {
        $kernel->post($sender, 'privmsg', $chan, "No @ for you, $who");
      }
    }
    elsif ($msg =~ /!addquote/ && $config{irc_quote}) {
      $kernel->post($sender, 'privmsg', $chan, "Sorry, function not implemented yet...");
    }
    elsif ($msg =~ /!delquote/ && $config{irc_quote}) {
      $kernel->post($sender, 'privmsg', $chan, "Sorry, function not implemented yet...");
    }
  }
}

sub irc_msg {
  my ($kernel, $sender, $who, $recip, $msg) = @_[KERNEL, SENDER, ARG0 .. ARG2];
  my @args=split(/ /, $msg);
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");

  print("IRC - irc_msg: $who: $msg\n") if $debug;
  
  if ($msg =~ /!help/) {
    &display_help($kernel, $sender, $who);
  }
  elsif ($msg =~ /!send_script/) {
    $kernel->post($sender, 'dcc', $who, 'send', 'test.txt' );
  }
  elsif ($msg =~ /!whoami/) {  
    print ("AUTH - $who requests WHOAMI\n") if $debug;
    if ($irc_authed{$who}) {
      $kernel->post($sender, 'privmsg', $who, "You are successfully authed, $who");
    }
    else {
      $kernel->post($sender, 'privmsg', $who, "You are not authed, $who");
    }
  }
  elsif ($msg =~ /!connected/) {
    $kernel->post($sender, 'privmsg', $who, "Sending test-command");
    $hl_result = &execute("connected $who");
  }
  elsif ($msg =~ /!version/) {
    $kernel->post($sender, 'privmsg', $who, "12,8     CS-to-IRC Bot - Version : $version from http://www.independent-lords.de     ");
  }
  elsif ($msg =~ /!qs/) {
    if ($args[1] eq "") {
      my @qstat = `./qstat -hls $config{hl_ip}:$config{hl_port} -nh -raw \";\"`;
      my @erg = split(/;/, $qstat[0]);
      $kernel->post($sender, 'privmsg', $who, "$erg[2] ($erg[1]) $erg[5]/$erg[4] $erg[3] $erg[6]ms");
    }
    else {
      my @qstat = `./qstat -hls $args[1] -nh -raw \";\"`;
      my @erg = split(/;/, $qstat[0]);
      $kernel->post($sender, 'privmsg', $who, "$erg[2] ($erg[1]) $erg[5]/$erg[4] $erg[3] $erg[6]ms");
    }
  }
  elsif ($msg =~ /!rules/) {  
    $kernel->post($sender, 'privmsg', $who, " ");
    $kernel->post($sender, 'privmsg', $who, "Querying serverrules from $config{hl_ip}:$config{hl_port}...");
    $kernel->post($sender, 'privmsg', $who, " ");
    my @qstat = `./qstat -hls $config{hl_ip}:$config{hl_port} -nh -R -raw \";\"`;
    my $counter=0;
    foreach my $zeile (@qstat) {
      my @erg = split(/;/, $zeile);
      foreach my $line (@erg) {
        $counter++;
        if ($counter >= 9) {
          $kernel->post($sender, 'privmsg', $who, $line);
          sleep 2;
        }
      }
    }
  }
  elsif ($msg =~ /!auth/) {
    if (! $args[2]) {
      $kernel->post($sender, 'privmsg', $who, "Usage: !auth username password");
    }
    else {        
      if (exists($irc_admins{$args[1]})) {
        if ($irc_admins{$args[1]} eq $args[2]) {
          $kernel->post($sender, 'privmsg', $who, "Access granted for user $args[1]");
          print ("AUTH - Access granted for user $args[1] with password $args[2]\n") if $debug;
          $irc_authed{$who} = 1;
        }
        else {
          $kernel->post($sender, 'privmsg', $who, "Access denied for user $args[1] - wrong password");
          print ("AUTH - Access denied for user $args[1] with password $args[2]\n") if $debug;
        }
      }
      else {
        $kernel->post($sender, 'privmsg', $who, "Access denied for user $args[1]");
        print ("AUTH - Access denied for user $args[1] - User not found.\n") if $debug;
      }
    }
  }
  elsif ($msg =~ /!status/) {
    $kernel->post($sender, 'privmsg', $who, " ");
    $kernel->post($sender, 'privmsg', $who, "Querying status from $config{hl_ip}:$config{hl_port}...");
    $kernel->post($sender, 'privmsg', $who, " ");
    $hl_result = &execute("status");
    my @splitresult = split(/\n/, $hl_result);
    foreach my $line (@splitresult) {
      $kernel->post($sender, 'privmsg', $who, $line);
    }
  }
  elsif ($msg =~ /!stats/) {  
    $kernel->post($sender, 'privmsg', $who, " ");
    $kernel->post($sender, 'privmsg', $who, "Current statistics");
    $kernel->post($sender, 'privmsg', $who, " ");
    $kernel->post($sender, 'privmsg', $who, "Team Counterterrorists");
    $kernel->post($sender, 'privmsg', $who, "--------------------------------");
    $kernel->post($sender, 'privmsg', $who, "Team Terrorists");
        
    open (STATS, ">>stats.log") || die "Konnte stats.log nicht oeffnen: $!";
    print STATS (map { "$_ => $teams{$_}\n" } keys %teams) if $debug;
    print STATS ("\n\n") if $debug;
    print STATS (map { "$_ => $hash_kills{$_}\n" } keys %hash_kills) if $debug;
    print STATS ("\n\n") if $debug;
    print STATS (map { "$_ => $hash_deaths{$_}\n" } keys %hash_deaths) if $debug;
    print STATS ("\n\n\n\n") if $debug;
    close (STATS);
 
    print (map { "$_ => $teams{$_}\n" } keys %teams) if $debug;
    print ("\n\n") if $debug;
    print (map { "$_ => $hash_kills{$_}\n" } keys %hash_kills) if $debug;
    print ("\n\n") if $debug;
    print (map { "$_ => $hash_deaths{$_}\n" } keys %hash_deaths) if $debug;
  }
  
  # These commands are only available to authed admins

  elsif ($irc_authed{$who}) {
    if (($msg =~ /!reconnect/) || ($msg =~ /!connect/)) {
      $kernel->post($sender, 'privmsg', $who, "Trying to register at the server...");
      &server_connect;
    }
    elsif ($msg =~ /!disconnect/) {
      $kernel->post($sender, 'privmsg', $who, "Stopping transmission from server...");
      delete $kernel->{socket_handle};
    }
    elsif ($msg =~ /!reload/) {
      @irc_quotes = ();
      %irc_admins = ();
      &LoadConfiguration;
      $kernel->post($sender, 'privmsg', $who, "Reloading configuration...");
    }
    elsif ($msg =~ /!quit/) {
      $kernel->post($sender, 'privmsg', $who, " ");
      $kernel->post($sender, 'privmsg', $who, "Quitting IRC, closing all connections...");
      $kernel->post($sender, 'privmsg', $who, " ");
      $kernel->post($sender, 'quit', $config{irc_quitmsg} );
    }
    elsif ($msg =~ /!t_chat/) {
      if ($args[1] eq "1") {
        $config{ev_t_chat}=1;
        $kernel->post($sender, 'privmsg', $who, "Showing Team-Chat...");
      }
      elsif ($args[1] eq "0") {
        $config{ev_t_chat}=0;
        $kernel->post($sender, 'privmsg', $who, "NOT Showing Team-Chat...");
      }
      else {
        if ($config{ev_t_chat}) {
          $kernel->post($sender, 'privmsg', $who, "Team-Chat is shown.");
        }
        else {
          $kernel->post($sender, 'privmsg', $who, "Team-Chat is NOT shown.");
        }
      }
    }
    elsif ($msg =~ /!chat/) {
      if ($args[1] eq "1") {
        $config{ev_chat}=1;
        $kernel->post($sender, 'privmsg', $who, "Showing Public-Chat...");
      }
      elsif ($args[1] eq "0") {
        $config{ev_chat}=0;
        $kernel->post($sender, 'privmsg', $who, "NOT Showing Public-Chat...");
      }
      else {
        if ($config{ev_chat}) {
          $kernel->post($sender, 'privmsg', $who, "Public-chat is shown.");
        }
        else {
          $kernel->post($sender, 'privmsg', $who, "Public-chat is NOT shown.");
        }
      }
    }
    elsif ($msg =~ /!say/) {
      my $say = "";
      $say = $args[1];
      
      for my $x (2 .. $#args) {
        $say = $say . " " . $args[$x];
      }
      $kernel->post($sender, 'privmsg', $config{irc_channel1}, $say);
    }
    elsif ($msg =~ /!cjoin/) {
      $kernel->post($sender, 'join', $args[1]);
    }
    elsif ($msg =~ /!announce/) {
      # DEBUG: Überprüfung, ob Bot bereits im Channel ist, muss noch eingebaut werden
      $kernel->post($sender, 'join', $args[1]);
      $kernel->post($sender, 'privmsg', $args[1], "Here's $config{irc_nick} speaking...");
      $kernel->post($sender, 'privmsg', $args[1], "I'm currently posting an important game to IRC");
      $kernel->post($sender, 'privmsg', $args[1], "Please join $config{irc_channel1} to watch!");
      $kernel->post($sender, 'part', $args[1]);
    }
    elsif ($msg =~ /!password/) {
      $kernel->post($sender, 'privmsg', $who, " ");
      $kernel->post($sender, 'privmsg', $who, "Querying password from $config{hl_ip}:$config{hl_port}...");
      $kernel->post($sender, 'privmsg', $who, " ");
      $hl_result = &execute("sv_password");
      $kernel->post($sender, 'privmsg', $who, $hl_result);
    }
    elsif ($msg =~ /!changelevel/) {
      $hl_result = &execute("changelevel $args[1]");
      if ($hl_result =~ /^changelevel failed: '(.+)' not found on server./) {
        $kernel->post($sender, 'privmsg', $who, $hl_result);
      }
      else {
        $kernel->post($sender, 'privmsg', $who, "Loading map $args[1]");
      }
    }
  }
  elsif ($msg =~ /.*/) {
    $kernel->post($sender, 'privmsg', $who, "Type \"!help\" for help on valid commands");
  }
}

sub irc_invite {
  my ($kernel, $sender, $who, $chan) = @_[KERNEL, SENDER, ARG0, ARG1];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  
  print ("IRC - irc_invite - $who invited me to join $chan\n") if $debug;
  $kernel->post($sender, 'join', $chan);
}

sub irc_quit {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0, ARG1];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  
  print ("IRC - irc_quit - $who quit IRC: $msg\n") if $debug;
}

sub irc_part {
  my ($kernel, $sender, $who, $chan) = @_[KERNEL, SENDER, ARG0, ARG1];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  
  print ("IRC - irc_part - $who left channel $chan\n") if $debug;
}

sub irc_ctcp_version {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  
  print ("IRC - irc_ctcp_version: $who\n") if $debug;
  $kernel->post($sender, 'ctcpreply', $who, "VERSION Counterstrike-To-IRC Bot $version (c)2001 magenbrot - http://www.independent-lords.de");
}

sub irc_ctcp_ping {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0, ARG2];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");
  
  print ("IRC - irc_ctcp_ping: $who - $msg\n") if $debug;
  $kernel->post($sender, 'ctcpreply', $who, "PING $msg");
}

sub irc_ctcp_time {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0, ARG2];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");

  print ("IRC - irc_ctcp_time: $who\n") if $debug;
  $kernel->post($sender, 'ctcpreply', $who, "TIME " . (strftime "%a %b %d %H:%M:%S %G %Z", localtime));
}

sub irc_ctcp_source {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0, ARG2];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");

  print ("IRC - irc_ctcp_source: $who\n") if $debug;
  $kernel->post($sender, 'ctcpreply', $who, "SOURCE http://www.independent-lords.de");
}

sub irc_ctcp_finger {
  my ($kernel, $sender, $who, $msg) = @_[KERNEL, SENDER, ARG0, ARG2];
  $who =~ s/^(.*)!.*$/$1/ || die ("Weird-ass who: $who");

  print ("IRC - irc_ctcp_finger: $who\n") if $debug;
  $kernel->post($sender, 'ctcpreply', $who, "FINGER Hey! Don't touch me!");
}

sub irc_dcc_done {
  my ($magic, $nick, $type, $port, $file, $size, $done) = @_[ARG0 .. ARG6];
  print ("DCC $type to $nick ($file) done: $done bytes transferred.\n") if $debug;
}

sub irc_dcc_error {
  my ($err, $nick, $type, $file) = @_[ARG0 .. ARG2, ARG4];
  print ("DCC $type to $nick ($file) failed: $err.\n") if $debug;
}

###############################################################################
# Display help in IRC
###############################################################################

sub display_help {
  my ($kernel, $sender, $who) = @_;

  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "$config{irc_nick} Commands on PRIVATE-channel:");
  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "!stats - Show current statistics");
  $kernel->post($sender, 'privmsg', $who, "!status - Serverstatus");
  $kernel->post($sender, 'privmsg', $who, "!connected - Are we connected or not?");
  $kernel->post($sender, 'privmsg', $who, "!rules - Serverrules");
  $kernel->post($sender, 'privmsg', $who, "!qs ip:port - Queries a server");
  $kernel->post($sender, 'privmsg', $who, "!qs - Queries directly the $config{hl_server_name} Server");
  $kernel->post($sender, 'privmsg', $who, "!auth username password - Authenticate with $config{irc_nick}");
  $kernel->post($sender, 'privmsg', $who, "!send_script - Sends the perl-script of the bot via DCC");
  $kernel->post($sender, 'privmsg', $who, "!version - Displays the version of the bot");
  if ($irc_authed{$who}) {
    $kernel->post($sender, 'privmsg', $who, "!reconnect - reconnect to the hl-cs server");
    $kernel->post($sender, 'privmsg', $who, "!password - Shows current serverpassword");
    $kernel->post($sender, 'privmsg', $who, "!chat 0/1 - Switch public_chat in IRC on (1) and off (0)");
    $kernel->post($sender, 'privmsg', $who, "!t_chat 0/1 - Switch team_chat in IRC on (1) and off (0)");
    $kernel->post($sender, 'privmsg', $who, "!say - say something as $config{irc_nick}");
    $kernel->post($sender, 'privmsg', $who, "!cjoin #channel - Force $config{irc_nick} to join #channel");
    $kernel->post($sender, 'privmsg', $who, "!changelevel xxx - Load map xxx on the hl-cs server");
    $kernel->post($sender, 'privmsg', $who, "!changelevel xxx - Load map xxx on the hl-cs server");
    $kernel->post($sender, 'privmsg', $who, "!quit - Force the bot to quit IRC");
  }
  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "$config{irc_nick} Commands on the PUBLIC-channel:");
  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "!qs ip:port - Queries a server");
  $kernel->post($sender, 'privmsg', $who, "!qs - Queries directly the $config{hl_server_name} Server");
  if ($config{irc_fortune}) {
    $kernel->post($sender, 'privmsg', $who, "!fortune - Print out a random fortune");
  }
  if ($config{irc_quote}) {
    $kernel->post($sender, 'privmsg', $who, "!quote [nr.] - Print out a random quote or the specified quote");
    if ($irc_authed{$who}) {
      $kernel->post($sender, 'privmsg', $who, "!addquote - Adds a new quote");
      $kernel->post($sender, 'privmsg', $who, "!delquote ## - Deletes quote number ##");
    }
  }
  $kernel->post($sender, 'privmsg', $who, "!send_script - Sends the perl-script of the bot via DCC");
  $kernel->post($sender, 'privmsg', $who, "!version - Displays the version of the bot");
  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "If you get an \"Rcon timeout\" issue the command again.");
  $kernel->post($sender, 'privmsg', $who, " ");
  $kernel->post($sender, 'privmsg', $who, "Problems, Hints, Tips:");
  $kernel->post($sender, 'privmsg', $who, "magenbrot\@independent-lords.de - Counterstrike-To-IRC Bot $version (c)2001");
}

###############################################################################
# Getting your internet-ip from external script
###############################################################################

sub get_ip {
  use LWP::UserAgent;
  use HTTP::Request;

  my $ua = LWP::UserAgent->new();
  $ua->agent("Braindead/v1.0");
  my $anf = HTTP::Request->new(GET => $config{inet_url});
  $anf->referer("http://www.independent-lords.de");
  my $antwort = $ua->request($anf);
  if ($antwort->is_error()) {
    return($antwort->status_line);
  }
  else {
    return($antwort->content());
  }
}

###############################################################################
# Connecting to the HL-server
###############################################################################

sub server_connect {
  print ("\nRCON - Sending 'logaddress' command to server...\n") if $debug;

  my $counter = 0;
  $hl_result = "Rcon timeout";
  while (($hl_result eq "Rcon timeout") && ($counter < $config{hl_retry})) {
    $hl_result = &execute("logaddress $inet_ip $config{inet_listen_port}");
    if ($hl_result eq "Rcon timeout") {
      print ("RCON - Got Rcon timeout, retrying...\n") if $debug;
      $counter++;
    }
  }

  if ($counter eq $config{hl_retry}) {
    print ("RCON - Could not send 'logaddress' command. Giving up...\n\n") if $debug;
    $hl_connected = 0;
  }
  else {
    print ("RCON - 'logaddress' command sent\n\n") if $debug;
    print ("RCON - Sending 'log on' command to server...\n") if $debug;
    $counter = 0;
    $hl_result = "Rcon timeout";
    while (($hl_result eq "Rcon timeout") && ($counter < $config{hl_retry})) {
      $hl_result = &execute("log on");
      if ($hl_result eq "Rcon timeout") {
        print ("RCON - Got Rcon timeout, retrying...\n") if $debug;
        $counter++;
      }
    }
    if ($counter eq $config{hl_retry}) {
      print ("RCON - Could not send 'log on' command. Giving up...\n\n") if $debug;
      $hl_connected = 0;
    }
    else {
      print ("RCON - 'log on' command sent\n\n") if $debug;
      print ("RCON - Sending 'mp_logmessages 1' command to server...\n") if $debug;
      $counter = 0;
      $hl_result = "Rcon timeout";
      while (($hl_result eq "Rcon timeout") && ($counter < $config{hl_retry})) {
        $hl_result = &execute("mp_logmessages 1");
        if ($hl_result eq "Rcon timeout") {
          print ("RCON - Got Rcon timeout, retrying...\n") if $debug;
          $counter++;
        }
      }
      if ($counter eq $config{hl_retry}) {
        print ("RCON - Could not send 'mp_logmessages 1' command. Giving up...\n\n") if $debug;
        $hl_connected = 0;
      }
      else {
        print ("RCON - 'mp_logmessages' command sent\n\n") if $debug;
        $hl_connected = 1;
      }
    }
  }

  if (! $hl_connected) {
    print ("RCON - We are not listening to the server. Please connect manually...\n\n") if $debug;
  }
  else {
    print ("RCON - Successfully registered us to the server...\n\n") if $debug;
    # DEBUG: # rausnehmen, damit sich der bot auf dem server anmeldet
    &execute("say This server is now transmitting to $config{irc_channel1} via $config{irc_nick}");
  }
}

###############################################################################
# RCON-Routine
###############################################################################

sub execute {
  my ($command) = @_;

  my $hl_rcon = new KKrcon(
    Host     => $config{hl_ip},
    Port     => $config{hl_port},
    Password => $config{hl_rcon_pw},
    Type     => $hl_type
  );

  print ("RCON - execute: $command\n") if $debug;
  my $answer = $hl_rcon->execute($command);
  if (my $error = $hl_rcon->error()) {
    print ("RCON - Error: $error\n") if $debug;
    return ($error);
  }
  else
  {
    print ("RCON - Answer: $answer") if $debug;
    return ($answer);
  }
}

###############################################################################
# UDP listening socket (to receive the cs-server messages
###############################################################################

sub udp_server_start {
  my ($kernel, $heap, $port) = @_[KERNEL, HEAP, ARG0];
  print ("INET - udp_server_start - Opening UDP listen socket on $inet_listen_ip:$config{inet_listen_port} ...\n") if $debug;

  if (defined ($heap->{socket_handle} = IO::Socket::INET->new( Proto => 'udp', LocalPort => $config{inet_listen_port} ))) {
    $kernel->select_read($heap->{socket_handle}, 'select_read');
  }
  else {
    die ("INET - udp_server_start - error ", ($!+0), " creating socket: $!\n");
  }
}

sub udp_server_stop {
  print ("INET - Closing UDP listen socket.\n") if $debug;
  delete $_[HEAP]->{socket_handle};
}

sub udp_server_receive {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];
  my $remote_socket = recv( $heap->{socket_handle}, my $message = '', POSIX::BUFSIZ, 0);

  if (defined $remote_socket) {
    my ($remote_port, $remote_addr) = unpack_sockaddr_in($remote_socket);
    my $human_addr = inet_ntoa($remote_addr);

    #print ("server: received message from $human_addr : $remote_port\n") if $debug;
    #print ("server: message=($message)\n") if $debug;
    &callback($kernel, $message);
  }
}

sub udp_server_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  print("INET - udp_server_error - $operation error $errnum: $errstr\n") if $debug;
  delete $heap->{socket_handle};
}

###############################################################################
# Load Bot-Configuration, Admins and Quotes
###############################################################################

sub LoadConfiguration {
  print ("\nCONFIG - Reading configuration... ") if $debug;
  open (CONFIG, "cs-irc.cfg") or die ("Error! No config file could be found: $!");
  READ: while(<CONFIG>) {
    next READ if /^#/;
    $config{$1} = $2 if /^(.*?)\s*=\s*(.*)$/;
  }
  close (CONFIG);
  print ("done loading configuration\n\n") if $debug;

  print ("ADMIN - Reading admin-configuration... ") if $debug;
  open (ADMIN, "admin.cfg") or die ("Error! No admin file could be found: $!");
  READ: while(<ADMIN>) {
    next READ if /^#/;
    $irc_admins{$1} = $2 if /^(.*?)\s*=\s*(.*)$/;
  }
  close (ADMIN);
  print ("done loading admin-configuration\n\n") if $debug;

  if ($config{irc_quote}) {
    my $counter = 0;
    print ("QUOTES - Reading quotes-file... ") if $debug;
    open (QUOTE, $config{irc_quote_file}) || die ("Can't load quotes: $!");
    while (<QUOTE>) {
      chomp;
      push(@irc_quotes, $_);
      $counter++;
    }
    close (QUOTE);
    if($counter eq 1) {
      print ("done loading $counter quote\n\n") if $debug;
    }
    else {
      print ("done loading $counter quotes\n\n") if $debug;
    }
  }
}

###############################################################################
# CS-Server to IRC Parser
###############################################################################

sub callback {
  my ($kernel, $data) = @_;

  $data =~ s/\n//g;
  $data =~ s/\r//g;
  $data = substr($data,33,length($data) - 34);
  print ("RCON - DATA: $data\n") if $debug;

  for ($data) {
    # Rcon: "rcon 3930165283 "xxx" connected magenbrot" from "217.81.195.221:61098"
    /^Rcon: "rcon (.+) "(.+)" connected (.+)" from "[0-9:\.].+"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $3, "Current status: connected to server $config{hl_ip}:$config{hl_port}");
    };

    # Server cvar "mp_limitteams" = "0"
    /^Server cvar "(.+)" = "(.+)"$/
    and do {
      if(! $hl_mapchange  && $1 ne "public_slots_free" && $config{ev_variable_change}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Servervariable changed: $1 => $2");
      }
      last;
    };

    # "i][Lords -=magenbrot=-<19><221147><>" entered the game
    /^"(.+)<.+><.+><>" entered the game$/
    and do {
      if ($config{ev_enter_leave}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$1 has entered the game");
      }
      $hash_kills{$1}=0;
      $hash_deaths{$1}=0;
      last;
    };

    # "i][Lords -=magenbrot=-<19><221147><>" connected, address "217.81.201.201:61049"
    /^"(.+)<.+><.+><>" connected, address "[0-9:\.].+"$/
    and do {
      if ($config{ev_connections}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$1 connected");
      }
      last;
    };

    # "i][Lords -=The_oNe*=-<15><11556><TERRORIST>" disconnected
    /^"(.+)<.+><.+><.+>" disconnected$/
    and do {
      if ($config{ev_connections}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 disconnected");
      }
      delete($hash_kills{$1});
      delete($hash_deaths{$1});
      delete($teams{$1});
      last;
    };

    # "i][Lords -=The_oNe*=-<24><11556><>" joined team "CT"
    /^"(.+)<.+><.+><.*>" joined team "(.+)"/
    and do {
      $player1=$1;
      if ($2 =~ /^CT$/) {
        $teams{$player1} = "12";
        if ($config{ev_team_joins}) {
          $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 joined the 12Counter-Terrorist team");
        }
      }
      else {
        $teams{$player1} = "4";
        if ($config{ev_team_joins}) {
          $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 joined the 4Terrorist team");
        }
      }
      last;
    };

    # World triggered "Game_Commencing"
    /^World triggered "Game_Commencing"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Game starts");
      #reinitialise
      $timer = 0;
      $timer_status = 0;
      last;
    };

    # Team "CT" triggered "CTs_Win" (CT "1") (T "0")
    /^Team "CT" triggered "CTs_Win" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "12Counter-Terrorists Win");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "TERRORIST" triggered "Terrorists_Win" (CT "2") (T "3")
    /^Team "TERRORIST" triggered "Terrorists_Win" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "4Terrorists Win");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "TERRORIST" triggered "Target_Bombed" (CT "4") (T "14")
    /^Team "TERRORIST" triggered "Target_Bombed" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "4Terrorists Win");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "CT" triggered "Target_Saved" (CT "1") (T "0")
    /^Team "CT" triggered "Target_Saved" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "12Counter-Terrorists Win3 (Target has been saved)");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "TERRORIST" triggered "Hostages_Not_Rescued" (CT "0") (T "1")
    /^Team ".+" triggered "Hostages_Not_Rescued" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "4Terrorists Win 3 (Hostages have NOT been rescued)");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "CT" triggered "All_Hostages_Rescued" (CT "3") (T "1")
    /^Team "CT" triggered "All_Hostages_Rescued" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "12Counter-Terrorists Win 3 (Hostages have been rescued)");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # World triggered "Round_Draw" (CT "16") (T "10")
    /^World triggered "Round_Draw" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Round Draw");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # World triggered "Round_Start"
    /^World triggered "Round_Start"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Round start");
      $hl_mapchange = 0;
      last;
    };

    # World triggered "Round_End"
    /^World triggered "Round_End"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Round end");
      last;
    };

    # "i][Lords -=NaTuRalH=-<8><758728><CT>" triggered "Touched_A_Hostage"
    /^"(.+)<.+><.+><.+>" triggered "Touched_A_Hostage"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 has a 3Hostage");
      last;
    };

    # "Player<17><11556><CT>" triggered "Killed_A_Hostage"
    /^"(.+)<.+><.+><.+>" triggered "Killed_A_Hostage"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 murdered a 3Hostage");
      last;
    };

    # "i][Lords -=NaTuRalH=-<8><758728><CT>" triggered "Rescued_A_Hostage"
    /^"(.+)<.+><.+><.+>" triggered "Rescued_A_Hostage"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 rescued a 3Hostage");
      last;
    };

    # "-=][Antifa][=--=sKaTePuNk=-<13><758728><CT>" killed "Hellangel<23><383961><TERRORIST>" with "grenade"
    /^"(.+)<.+><.+><(.+)>" killed "(.+)<.+><.+><(.+)>" with "(.+)"$/
    and do {
      $player1 = $1;
      $player2 = $3;
      $weapon = $5;
      if ($2 =~ /^CT$/) {
        $teams{$player1} = "12";
      }
      else {
        $teams{$player1} = "4";
      }

      if ($4 =~ /^CT$/) {
        $teams{$player2} = "12";
      }
      else {
        $teams{$player2} = "4";
      }

      $hash_kills{$player1} += 1;
      $hash_deaths{$player2} += 1;
      
      if ($config{ev_kill}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 killed $teams{$player2}$player2 with 3$weapon");
      }
      last;
    };

    /^"(.+)<.+><.+><CT>" killed "(.+)<.+><.+><CT>" with "(.+)"$/
    and do {
      if ($config{ev_kill}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 7teamkilled $teams{$player2}$player2 with 3$weapon");
      }
      last;
    };

    /^"(.+)<.+><.+><TERRORIST>" killed "(.+)<.+><.+><TERRORIST>" with "(.+)"$/
    and do {
      if ($config{ev_kill}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 7teamkilled $teams{$player2}$player2 with 3$weapon");
      }
      last;
    };

    # "telefon<19><221147><TERRORIST>" committed suicide with "world"
    /^"(.+)<.+><.+><(.+)>" committed suicide.+$/
    and do {
      $player1 = $1;
      $weapon = $4;
      $hash_kills{$player1} -= 1;
      $hash_deaths{$player1} += 1;
      if ($config{ev_suicides}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 fell to his death");
      }
      last;
    };

    # DEBUG: gibts das überhaupt noch?
    /^"(.+)<.+><.+><(.+)>" killed self with "(.+)".+$/
    and do {
      $player1 = $1;
      $weapon = $3;
      if ($2 =~ /^CT$/) {
        $teams{$player1} = "12";
      }
      if ($2 =~ /^TERRORIST$/) {
        $teams{$player1} = "4";
      }
      $hash_kills{$player1} -= 1;
      $hash_deaths{$player1} += 1;
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$player1}$player1 killed 14Self with 3$weapon");
      last;
    };

    # "i][Lords -=magenbrot=-<19><221147><CT>" changed name to "telefon"
    /^"(.+)<.+><.+><(.+)>" changed name to "(.+)"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 changed name to $teams{$1}$3");
      $hash_kills{$3}=$hash_kills{$1};
      $hash_deaths{$3}=$hash_deaths{$1};
      $teams{$3}=$teams{$1};
      delete($hash_kills{$1});
      delete($hash_deaths{$1});
      delete($teams{$1});
      last;
    };

    # "Hellangel<23><383961><TERRORIST>" triggered "Spawned_With_The_Bomb"
    /^"(.+)<.+><.+><.+>" triggered "Spawned_With_The_Bomb"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 10spawned with the Bomb");
      last;
    };

    # "Hellangel<23><383961><TERRORIST>" triggered "Dropped_The_Bomb"
    /^"(.+)<.+><.+><.+>" triggered "Dropped_The_Bomb"$/
    and do {
      if ($config{ev_bomb_drop_get}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 10dropped the Bomb!");
      }
      last;
    };

    # "IceTea-Sparkling<21><383961><TERRORIST>" triggered "Got_The_Bomb"
    /^"(.+)<.+><.+><.+>" triggered "Got_The_Bomb"$/
    and do {
      if ($config{ev_bomb_drop_get}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 10picked up the Bomb!");
      }
      last;
    };

    # "IceTea-Sparkling<21><383961><TERRORIST>" triggered "Planted_The_Bomb"
    /^"(.+)<.+><.+><.+>" triggered "Planted_The_Bomb"$/
    and do {
      if ($config{ev_bomb_plant_defuse}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 10planted the Bomb!");
      }
      last;
    };

    # Team "TERRORIST" triggered "Target_Bombed" (CT "2") (T "0")
    #/^Team "TERRORIST" triggered "Target_Bombed".+$/
    #and do {
    #  $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "-=*15T14arget 15S14uccessfully 15B14ombed*=-");
    #  last;
    #};

    # "-=][Antifa][=--=sKaTePuNk=-<13><758728><CT>" triggered "Begin_Bomb_Defuse_With_Kit"
    /^"(.+)<.+><.+><(.+)>" triggered "Begin_Bomb_Defuse_With_Kit"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 starts defusing the Bomb (with kit)");
      last;
    };

    # "telefon<19><221147><CT>" triggered "Begin_Bomb_Defuse_Without_Kit"
    /^"(.+)<.+><.+><(.+)>" triggered "Begin_Bomb_Defuse_Without_Kit"$/
    and do {
      if ($config{ev_bomb_plant_defuse}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 starts defusing the Bomb (without kit)");
      }
      last;
    };

    # "-=][Antifa][=--=sKaTePuNk=-<13><758728><CT>" triggered "Defused_The_Bomb"
    /^"(.+)<.+><.+><(.+)>" triggered "Defused_The_Bomb"$/
    and do {
      if ($config{ev_bomb_plant_defuse}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$teams{$1}$1 has defused the Bomb");
      }
      last;
    };

    # Team "TERRORIST" triggered "Target_Bombed" (CT "31") (T "15")
    /^Team "TERRORIST" triggered "Target_Bombed" \(CT "(.+)"\) \(T "(.+)"\)$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "4Terrorists Win 3 (Target bombed)");
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Score: 12Counter Terrorists $1, 4Terrorists $2");
      last;
    };

    # Team "CT" scored "1" with "0" players
    # Team "TERRORIST" scored "4" with "1" players
    /^"Team "(.+)" scored "(.+)" with "(.+)" players$/
    and do {
      if ($2 =~ /^CT$/) {
        $color = "12CT";
      }
      else {
        $color = "4TERRORIST";
      }
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "$colorscored $2 with $3 players");
      last;
    };

    # "telefon<19><221147><CT>" say "fuck the telefon"
    if ($config{ev_chat}) {
      /^"(.+)<.+><.+><(.+)>" say "(.+)"$/
      and do {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "(Public) $teams{$1}$1 : $3");
        last;
      };
    }

    # "][-=I.W.G=-][HITMAN<42><14238><CT>" say_team "ka"
    /^"(.+)<.+><.+><(.+)>" say_team "(.+)"$/
    and do {
      if ($config{ev_t_chat}) {
        $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "(Team) $teams{$1}$1 : $3");
      }
      last;
    };

    /^"sv_restartround" = "0.000000"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "3Match Restarted");
      last;
    };

    # Loading map "de_inferno"
    /^Loading map "(.+)"$/
    and do {
      $kernel->post($config{irc_nick}, 'privmsg', $config{irc_channel1}, "Started map 3$1");
      %teams = ();
      %hash_kills = ();
      %hash_deaths = ();
      $timer = 0;
      $timer_status = 0;

      $hl_mapchange = 1;
      &server_connect;
      last;
    };
  }
}

###############################################################################
# The end :>
###############################################################################
