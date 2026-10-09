##############################################
# $Id: 74_SamsungTizenWS.pm 0.1.0 2026-10-09 $
#
# FHEM module: Samsung Smart TVs with Tizen (2016 and newer) over the secure remote WebSocket (port 8002, token pairing).
# - the TV shows a one-time "allow" dialog; the token it returns is stored in the FHEM key store
# - remote keys, app launch, installed apps, power state (REST), power on via Wake-on-LAN
# License: GPL-2.0-or-later
#
package main;

use strict;
use warnings;

use JSON;
use MIME::Base64;
use IO::Socket::INET;
use Time::HiRes qw(gettimeofday);

use HttpUtils;
use DevIo;

my $STWS_VERSION = '0.1.0';

# keys offered in the set list (any other KEY_* name works with "set <name> key KEY_...")
my @STWS_KEYS = qw(KEY_UP KEY_DOWN KEY_LEFT KEY_RIGHT KEY_ENTER KEY_RETURN KEY_HOME KEY_MENU KEY_SOURCE KEY_INFO KEY_EXIT
  KEY_VOLUP KEY_VOLDOWN KEY_MUTE KEY_CHUP KEY_CHDOWN KEY_PLAY KEY_PAUSE KEY_STOP KEY_REWIND KEY_FF KEY_GUIDE KEY_TOOLS
  KEY_0 KEY_1 KEY_2 KEY_3 KEY_4 KEY_5 KEY_6 KEY_7 KEY_8 KEY_9 KEY_RED KEY_GREEN KEY_YELLOW KEY_BLUE);

# friendly set commands -> key
my %STWS_SHORT = (
  volumeUp => 'KEY_VOLUP', volumeDown => 'KEY_VOLDOWN', mute => 'KEY_MUTE',
  channelUp => 'KEY_CHUP', channelDown => 'KEY_CHDOWN',
  up => 'KEY_UP', down => 'KEY_DOWN', left => 'KEY_LEFT', right => 'KEY_RIGHT', ok => 'KEY_ENTER',
  back => 'KEY_RETURN', home => 'KEY_HOME', menu => 'KEY_MENU', source => 'KEY_SOURCE', info => 'KEY_INFO', exit => 'KEY_EXIT',
  play => 'KEY_PLAY', pause => 'KEY_PAUSE', stop => 'KEY_STOP',
);

sub SamsungTizenWS_Initialize {
  my ($hash) = @_;

  $hash->{DefFn}      = 'SamsungTizenWS_Define';
  $hash->{UndefFn}    = 'SamsungTizenWS_Undef';
  $hash->{DeleteFn}   = 'SamsungTizenWS_Delete';
  $hash->{ShutdownFn} = 'SamsungTizenWS_Shutdown';
  $hash->{SetFn}      = 'SamsungTizenWS_Set';
  $hash->{GetFn}      = 'SamsungTizenWS_Get';
  $hash->{AttrFn}     = 'SamsungTizenWS_Attr';
  $hash->{ReadFn}     = 'SamsungTizenWS_Read';
  $hash->{ReadyFn}    = 'SamsungTizenWS_Ready';

  $hash->{AttrList} = 'disable:1,0 interval clientName restPort wolMac wolBroadcast wolPort keyDelay '
                    . $readingFnAttributes;
}

# ---------------------------------------------------------------- define / undef
sub SamsungTizenWS_Define {
  my ($hash, $def) = @_;
  my @a = split(/[ \t]+/, $def);
  return 'Usage: define <name> SamsungTizenWS <host> [port]' if (@a < 3 || @a > 4);

  my $name = $a[0];
  $hash->{HOST}    = $a[2];
  $hash->{PORT}    = $a[3] // 8002;
  $hash->{VERSION} = $STWS_VERSION;
  $hash->{helper}  = { gen => 0 };

  SamsungTizenWS_SetState($hash, 'initialized');
  if ($init_done) {
    InternalTimer(gettimeofday() + 1, 'SamsungTizenWS_Poll', $hash, 0);
  } else {
    InternalTimer(gettimeofday() + 20, 'SamsungTizenWS_Poll', $hash, 0);
  }
  return undef;
}

sub SamsungTizenWS_Undef {
  my ($hash, $arg) = @_;
  RemoveInternalTimer($hash);
  SamsungTizenWS_CloseWs($hash);
  return undef;
}

sub SamsungTizenWS_Delete {
  my ($hash, $name) = @_;
  setKeyValue($name . '_token', undef);
  return undef;
}

sub SamsungTizenWS_Shutdown {
  my ($hash) = @_;
  SamsungTizenWS_CloseWs($hash);
  return undef;
}

# ---------------------------------------------------------------- helpers
sub SamsungTizenWS_Token {
  my ($hash) = @_;
  my ($err, $tok) = getKeyValue($hash->{NAME} . '_token');
  return $tok;
}

sub SamsungTizenWS_SetState {
  my ($hash, $state) = @_;
  return if (ReadingsVal($hash->{NAME}, 'state', '') eq $state);
  readingsSingleUpdate($hash, 'state', $state, 1);
}

sub SamsungTizenWS_ClientName {
  my ($hash) = @_;
  return AttrVal($hash->{NAME}, 'clientName', 'FHEM');
}

sub SamsungTizenWS_RestUrl {
  my ($hash, $path) = @_;
  return 'http://' . $hash->{HOST} . ':' . AttrVal($hash->{NAME}, 'restPort', 8001) . $path;
}

# ---------------------------------------------------------------- polling (REST /api/v2/)
sub SamsungTizenWS_Poll {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash, 'SamsungTizenWS_Poll');
  my $iv = AttrVal($name, 'interval', 30);
  $iv = 30 if ($iv !~ /^\d+$/ || $iv < 5);
  InternalTimer(gettimeofday() + $iv, 'SamsungTizenWS_Poll', $hash, 0);
  return if (IsDisabled($name));

  HttpUtils_NonblockingGet({
    url      => SamsungTizenWS_RestUrl($hash, '/api/v2/'),
    timeout  => 4,
    hash     => $hash,
    callback => \&SamsungTizenWS_PollDone,
  });
}

sub SamsungTizenWS_PollDone {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  my $j = (!$err && ($param->{code} // 0) == 200 && $data) ? eval { decode_json($data) } : undef;
  if (ref($j) ne 'HASH') {                         # not reachable: TV is off (or network standby without answer)
    SamsungTizenWS_TvOff($hash);
    return;
  }

  my $d = ref($j->{device}) eq 'HASH' ? $j->{device} : {};
  my $power = lc($d->{PowerState} // 'on');         # PowerState appears on newer models: on | standby
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, 'presence', 'present');
  readingsBulkUpdateIfChanged($hash, 'power', $power);
  readingsBulkUpdateIfChanged($hash, 'modelName', $d->{modelName}) if (defined $d->{modelName});
  if (defined $d->{name}) { my $n = $d->{name}; utf8::encode($n) if (utf8::is_utf8($n)); readingsBulkUpdateIfChanged($hash, 'tvName', $n); }
  readingsBulkUpdateIfChanged($hash, 'resolution', $d->{resolution}) if (defined $d->{resolution});
  readingsBulkUpdateIfChanged($hash, 'os', $d->{OS}) if (defined $d->{OS});
  readingsBulkUpdateIfChanged($hash, 'wifiMac', $d->{wifiMac}) if (defined $d->{wifiMac});
  readingsBulkUpdateIfChanged($hash, 'networkType', $d->{networkType}) if (defined $d->{networkType});
  readingsEndUpdate($hash, 1);
  $hash->{helper}{info} = $d;

  if ($power ne 'on') {
    SamsungTizenWS_CloseWs($hash);
    SamsungTizenWS_SetState($hash, 'standby');
    return;
  }
  if (!$hash->{helper}{ws}) {
    if (($hash->{helper}{noReconnectUntil} // 0) < time()) {
      delete $hash->{helper}{noReconnectUntil};
      SamsungTizenWS_OpenWs($hash);
    } else {
      SamsungTizenWS_SetState($hash, 'on');       # pairing was denied: wait before asking again (or: set pairingReset)
    }
  }
}

sub SamsungTizenWS_TvOff {
  my ($hash) = @_;
  SamsungTizenWS_CloseWs($hash);
  readingsBeginUpdate($hash);
  readingsBulkUpdateIfChanged($hash, 'presence', 'absent');
  readingsBulkUpdateIfChanged($hash, 'power', 'off');
  readingsEndUpdate($hash, 1);
  SamsungTizenWS_SetState($hash, 'off');
}

# ---------------------------------------------------------------- websocket
sub SamsungTizenWS_WsName { return $_[0]->{NAME} . '.ws'; }

sub SamsungTizenWS_OpenWs {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return if ($hash->{helper}{ws});

  my $tok  = SamsungTizenWS_Token($hash);
  my $path = '/api/v2/channels/samsung.remote.control?name=' . MIME::Base64::encode_base64(SamsungTizenWS_ClientName($hash), '')
           . ($tok ? '&token=' . $tok : '');
  my $cname = SamsungTizenWS_WsName($hash);
  my $chash = {
    NAME          => $cname,
    TYPE          => $hash->{TYPE},
    DeviceName    => "wss:$hash->{HOST}:$hash->{PORT}$path",
    sslargs       => { SSL_verify_mode => 0 },
    devioLoglevel => 4,
    phash         => $hash,
    TEMPORARY     => 1,
    NR            => $devcount++,
    nrPackets     => 0,
  };
  $attr{$cname}{comment} = 'do NOT delete (websocket of ' . $name . ')';
  $attr{$cname}{room}    = 'hidden';
  $defs{$cname}          = $chash;
  $hash->{helper}{ws}    = $chash;
  $hash->{helper}{ready} = 0;
  $hash->{helper}{queue} = [];

  SamsungTizenWS_SetState($hash, $tok ? 'connecting' : 'pairing');
  readingsSingleUpdate($hash, 'tokenState', $tok ? 'paired' : 'waiting for TV confirmation', 1);
  Log3 $name, 3, "$name: opening websocket" . ($tok ? '' : " (no token yet - confirm the dialog on the TV)");

  DevIo_OpenDev($chash, 0, undef, sub {
    my ($ch, $err) = @_;
    if ($err) {
      Log3 $name, 3, "$name: websocket: $err";
      SamsungTizenWS_WsClosed($ch);
    }
  });
}

sub SamsungTizenWS_CloseWs {
  my ($hash) = @_;
  my $ch = delete $hash->{helper}{ws};
  $hash->{helper}{ready} = 0;
  return if (!$ch);
  DevIo_CloseDev($ch);
  delete $ch->{DevIoJustClosed};
  delete $ch->{NEXT_OPEN};
  delete $attr{ $ch->{NAME} };
  delete $defs{ $ch->{NAME} };
}

sub SamsungTizenWS_Ready { return undef; }      # reconnects are handled by the poll timer

sub SamsungTizenWS_WsClosed {
  my ($ch) = @_;
  my $hash = $ch->{phash} or return;
  return if (!$hash->{helper}{ws} || $hash->{helper}{ws} != $ch);
  Log3 $hash->{NAME}, 3, "$hash->{NAME}: websocket closed";
  SamsungTizenWS_CloseWs($hash);
  SamsungTizenWS_SetState($hash, 'on');
}

sub SamsungTizenWS_Read {
  my ($ch) = @_;
  my $buf = DevIo_SimpleRead($ch);
  if (!defined $buf) { SamsungTizenWS_WsClosed($ch); return; }
  return if ($buf eq '');

  my $hash = $ch->{phash} or return;
  my $name = $hash->{NAME};
  Log3 $name, 5, "$name: ws <- $buf";
  my $j = eval { decode_json($buf) };
  return if (ref($j) ne 'HASH');

  my $ev = $j->{event} // '';
  my $dd = ref($j->{data}) eq 'HASH' ? $j->{data} : {};

  if ($ev eq 'ms.channel.connect') {
    if (defined $dd->{token} && $dd->{token} ne '') {
      my $old = SamsungTizenWS_Token($hash);
      if (!$old || $old ne $dd->{token}) {
        setKeyValue($name . '_token', $dd->{token});
        Log3 $name, 3, "$name: pairing successful, token stored";
      }
    }
    readingsSingleUpdate($hash, 'tokenState', 'paired', 1);
    SamsungTizenWS_SetState($hash, 'connected');
    SamsungTizenWS_Ready_($hash);                 # older Tizen TVs (e.g. 2018) never send ms.channel.ready: the connect event is enough
  }
  elsif ($ev eq 'ms.channel.ready') {
    SamsungTizenWS_SetState($hash, 'connected');
    SamsungTizenWS_Ready_($hash);
  }
  elsif ($ev eq 'ms.channel.timeOut' || $ev eq 'ms.error' || $ev eq 'ms.channel.unauthorized') {
    Log3 $name, 2, "$name: TV refused the connection ($ev) - pairing denied or timed out";
    readingsSingleUpdate($hash, 'tokenState', 'denied', 1);
    $hash->{helper}{noReconnectUntil} = time() + 300;
    SamsungTizenWS_CloseWs($hash);
    SamsungTizenWS_SetState($hash, 'on');
  }
  elsif ($ev eq 'ed.installedApp.get') {
    my $list = ref($dd->{data}) eq 'ARRAY' ? $dd->{data} : [];
    my %apps;
    foreach my $a (@$list) {
      next if (ref($a) ne 'HASH' || !defined $a->{name} || !defined $a->{appId});
      my $n = $a->{name};
      utf8::encode($n) if (utf8::is_utf8($n));       # FHEM readings hold UTF-8 bytes (names may contain umlauts or special characters)
      $apps{$n} = $a->{appId};
    }
    $hash->{helper}{apps} = \%apps;
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'appCount', scalar(keys %apps));
    readingsBulkUpdate($hash, 'apps', join(',', sort { lc($a) cmp lc($b) } keys %apps));
    readingsEndUpdate($hash, 1);
  }
  else {
    Log3 $name, 4, "$name: ws event $ev";
  }
}

sub SamsungTizenWS_Ready_ {
  my ($hash) = @_;
  return if ($hash->{helper}{ready});
  $hash->{helper}{ready} = 1;
  my @q = @{ $hash->{helper}{queue} // [] };
  $hash->{helper}{queue} = [];
  SamsungTizenWS_Send($hash, $_) foreach (@q);
}

sub SamsungTizenWS_Send {
  my ($hash, $msg) = @_;
  my $ch = $hash->{helper}{ws};
  if (!$ch || !$hash->{helper}{ready}) {
    push @{ $hash->{helper}{queue} }, $msg;
    return 0;
  }
  my $text = ref($msg) ? encode_json($msg) : $msg;
  Log3 $hash->{NAME}, 5, "$hash->{NAME}: ws -> $text";
  DevIo_SimpleWrite($ch, $text, 2);
  return 1;
}

sub SamsungTizenWS_KeyMsg {
  my ($key, $cmd) = @_;
  return { method => 'ms.remote.control', params => { Cmd => ($cmd // 'Click'), DataOfCmd => $key, Option => 'false', TypeOfRemote => 'SendRemoteKey' } };
}

sub SamsungTizenWS_SendKey {
  my ($hash, $key) = @_;
  my $name = $hash->{NAME};
  return "TV is off (use: set $name on)" if (ReadingsVal($name, 'power', 'off') ne 'on');
  return "invalid key $key" if ($key !~ /^KEY_[A-Z0-9_]+$/);
  if (!$hash->{helper}{ws}) {
    SamsungTizenWS_OpenWs($hash);
  }
  SamsungTizenWS_Send($hash, SamsungTizenWS_KeyMsg($key));
  readingsSingleUpdate($hash, 'lastKey', $key, 1);
  if ($key eq 'KEY_POWER') {                  # check the new power state soon
    RemoveInternalTimer($hash, 'SamsungTizenWS_Poll');
    InternalTimer(gettimeofday() + 6, 'SamsungTizenWS_Poll', $hash, 0);
  }
  return undef;
}

# ---------------------------------------------------------------- Wake-on-LAN
sub SamsungTizenWS_Wol {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $mac  = AttrVal($name, 'wolMac', '');
  return "attribute wolMac (MAC address of the TV's LAN or Wi-Fi interface) is not set" if ($mac eq '');
  (my $hex = $mac) =~ s/[:\-\s]//g;
  return "invalid MAC address $mac" if ($hex !~ /^[0-9a-fA-F]{12}$/);

  my $packet = ("\xff" x 6) . (pack('H12', $hex) x 16);
  my $sock = IO::Socket::INET->new(Proto => 'udp', PeerAddr => AttrVal($name, 'wolBroadcast', '255.255.255.255'),
                                   PeerPort => AttrVal($name, 'wolPort', 9), Broadcast => 1)
    or return "WOL socket: $!";
  $sock->send($packet);
  $sock->close;
  Log3 $name, 3, "$name: Wake-on-LAN sent to $mac";
  readingsSingleUpdate($hash, 'lastWol', FmtDateTime(time()), 1);
  return undef;
}

# ---------------------------------------------------------------- set / get
sub SamsungTizenWS_Set {
  my ($hash, $name, $cmd, @args) = @_;
  my $apps = join(',', map { (my $x = $_) =~ s/[,\s]+/_/g; $x } sort { lc($a) cmp lc($b) } keys %{ $hash->{helper}{apps} // {} });
  my $list = 'on:noArg off:noArg power:noArg key:' . join(',', @STWS_KEYS) . ' keys:textField '
           . join(' ', map { "$_:noArg" } sort keys %STWS_SHORT)
           . ' app:' . ($apps ne '' ? $apps : 'textField') . ' refreshApps:noArg pairingReset:noArg';

  return "\"set $name\" needs at least one argument" if (!defined $cmd);
  return "Unknown argument $cmd, choose one of $list" if ($cmd eq '?');

  if (IsDisabled($name) && $cmd ne 'pairingReset') {
    return "$name is disabled";
  }

  if ($cmd eq 'on') {
    my $r = SamsungTizenWS_Wol($hash);
    return $r if ($r);
    InternalTimer(gettimeofday() + 8, 'SamsungTizenWS_Poll', $hash, 0);
    return undef;
  }
  if ($cmd eq 'off') {
    return undef if (ReadingsVal($name, 'power', 'off') ne 'on');       # already off / standby
    return SamsungTizenWS_SendKey($hash, 'KEY_POWER');
  }
  if ($cmd eq 'power') {
    return SamsungTizenWS_Wol($hash) if (ReadingsVal($name, 'power', 'off') ne 'on');
    return SamsungTizenWS_SendKey($hash, 'KEY_POWER');
  }
  if ($cmd eq 'key') {
    return "Usage: set $name key <KEY_NAME>" if (!@args);
    return SamsungTizenWS_SendKey($hash, uc($args[0]));
  }
  if ($cmd eq 'keys') {                      # several keys, comma separated, e.g. KEY_HOME,KEY_RIGHT,KEY_ENTER
    my @k = grep { $_ ne '' } split(/[,\s]+/, join(' ', @args));
    return "Usage: set $name keys KEY_A,KEY_B,..." if (!@k);
    foreach my $k (@k) { return "invalid key $k" if (uc($k) !~ /^KEY_[A-Z0-9_]+$/); }
    my $delay = AttrVal($name, 'keyDelay', 300);
    my $t = 0;
    foreach my $k (@k) {
      InternalTimer(gettimeofday() + $t / 1000, sub { SamsungTizenWS_SendKey($hash, uc($k)); }, "$name-key-" . ($t + int(rand(100000))), 0);
      $t += $delay;
    }
    return undef;
  }
  if (exists $STWS_SHORT{$cmd}) {
    return SamsungTizenWS_SendKey($hash, $STWS_SHORT{$cmd});
  }
  if ($cmd eq 'app') {
    return "Usage: set $name app <name or appId>" if (!@args);
    return SamsungTizenWS_LaunchApp($hash, join(' ', @args));
  }
  if ($cmd eq 'refreshApps') {
    return SamsungTizenWS_RequestApps($hash);
  }
  if ($cmd eq 'pairingReset') {
    setKeyValue($name . '_token', undef);
    SamsungTizenWS_CloseWs($hash);
    delete $hash->{helper}{noReconnectUntil};
    readingsSingleUpdate($hash, 'tokenState', 'missing', 1);
    InternalTimer(gettimeofday() + 1, 'SamsungTizenWS_Poll', $hash, 0);
    return undef;
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub SamsungTizenWS_RequestApps {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  return "TV is off (use: set $name on)" if (ReadingsVal($name, 'power', 'off') ne 'on');
  SamsungTizenWS_OpenWs($hash) if (!$hash->{helper}{ws});
  SamsungTizenWS_Send($hash, { method => 'ms.channel.emit', params => { event => 'ed.installedApp.get', to => 'host' } });
  return undef;
}

sub SamsungTizenWS_LaunchApp {
  my ($hash, $what) = @_;
  my $name = $hash->{NAME};
  return "TV is off (use: set $name on)" if (ReadingsVal($name, 'power', 'off') ne 'on');

  my $id = $what;
  my %apps = %{ $hash->{helper}{apps} // {} };
  (my $w = $what) =~ s/_/ /g;
  foreach my $n (keys %apps) {
    if (lc($n) eq lc($what) || lc($n) eq lc($w)) { $id = $apps{$n}; last; }
  }
  return "unknown app '$what' (run: set $name refreshApps, or use the numeric appId)" if ($id !~ /^[A-Za-z0-9._\-]+$/);

  SamsungTizenWS_OpenWs($hash) if (!$hash->{helper}{ws});
  SamsungTizenWS_Send($hash, { method => 'ms.channel.emit',
                               params => { event => 'ed.apps.launch', to => 'host', data => { appId => $id, action_type => 'DEEP_LINK' } } });
  readingsSingleUpdate($hash, 'lastApp', $what, 1);
  return undef;
}

sub SamsungTizenWS_Get {
  my ($hash, $name, $cmd, @args) = @_;
  my $list = 'info:noArg apps:noArg';
  return "\"get $name\" needs at least one argument" if (!defined $cmd);
  if ($cmd eq 'info') {
    return 'no data yet (TV off?)' if (ref($hash->{helper}{info}) ne 'HASH');
    return JSON->new->canonical->pretty->encode($hash->{helper}{info});
  }
  if ($cmd eq 'apps') {
    my %apps = %{ $hash->{helper}{apps} // {} };
    return 'no app list yet - run: set ' . $name . ' refreshApps' if (!%apps);
    return join("\n", map { sprintf('%-30s %s', $_, $apps{$_}) } sort { lc($a) cmp lc($b) } keys %apps);
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub SamsungTizenWS_Attr {
  my ($cmd, $name, $attr, $val) = @_;
  if ($cmd eq 'set') {
    if ($attr eq 'interval' && ($val !~ /^\d+$/ || $val < 5)) { return 'interval must be a number of seconds (minimum 5)'; }
    if ($attr eq 'keyDelay' && ($val !~ /^\d+$/ || $val > 5000)) { return 'keyDelay: milliseconds (0..5000)'; }
    if ($attr eq 'restPort' && ($val !~ /^\d+$/ || $val < 1 || $val > 65535)) { return 'restPort must be a port number'; }
  }
  if ($attr eq 'disable' && $init_done) {
    my $hash = $defs{$name};
    if ($cmd eq 'set' && $val) {
      RemoveInternalTimer($hash, 'SamsungTizenWS_Poll');
      SamsungTizenWS_CloseWs($hash);
      readingsSingleUpdate($hash, 'state', 'disabled', 1);
    } else {
      InternalTimer(gettimeofday() + 1, 'SamsungTizenWS_Poll', $hash, 0);
    }
  }
  return undef;
}

1;

=pod
=item device
=item summary    Samsung Smart TV (Tizen) over the secure remote WebSocket with token pairing
=item summary_DE Samsung Smart TV (Tizen) &uuml;ber den sicheren Remote-WebSocket mit Token-Kopplung
=begin html

<a name="SamsungTizenWS"></a>
<h3>SamsungTizenWS</h3>
<ul>
  Controls Samsung Smart TVs with Tizen (about 2016 and newer) over the secure remote WebSocket (port 8002).
  On the first connection the TV shows a dialog on the screen; after you confirm it with the TV remote, the TV returns a token that the module stores in the FHEM key store.
  <br><br>
  <a name="SamsungTizenWSdefine"></a>
  <b>Define</b>
  <ul><code>define &lt;name&gt; SamsungTizenWS &lt;host&gt; [port]</code> (port defaults to 8002)</ul><br>
  <a name="SamsungTizenWSset"></a>
  <b>Set</b>
  <ul>
    <li><code>on</code> &ndash; Wake-on-LAN (needs attribute <code>wolMac</code>; the TV setting &quot;Power on with mobile device / network standby&quot; must be on)</li>
    <li><code>off</code>, <code>power</code> &ndash; KEY_POWER (power toggles via Wake-on-LAN when the TV is off)</li>
    <li><code>key &lt;KEY_NAME&gt;</code>, <code>keys KEY_A,KEY_B,...</code> &ndash; remote keys; short commands: volumeUp, volumeDown, mute, channelUp, channelDown, up, down, left, right, ok, back, home, menu, source, info, exit, play, pause, stop</li>
    <li><code>app &lt;name|appId&gt;</code>, <code>refreshApps</code> &ndash; launch an app / read the list of installed apps</li>
    <li><code>pairingReset</code> &ndash; delete the stored token (the TV asks again)</li>
  </ul><br>
  <a name="SamsungTizenWSget"></a>
  <b>Get</b>
  <ul><li><code>info</code> (device data of the TV), <code>apps</code> (installed apps)</li></ul><br>
  <a name="SamsungTizenWSattr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code> &ndash; REST poll interval in seconds (default 30, minimum 5)</li>
    <li><code>clientName</code> &ndash; name shown on the TV (default FHEM)</li>
    <li><code>restPort</code> &ndash; port of the REST info API (default 8001)</li>
    <li><code>wolMac</code>, <code>wolBroadcast</code>, <code>wolPort</code> &ndash; Wake-on-LAN target (MAC of the TV, broadcast address, port 9)</li>
    <li><code>keyDelay</code> &ndash; pause between keys of <code>keys</code> in ms (default 300)</li>
    <li><code>disable</code></li>
  </ul><br>
  <b>Readings</b>: state (off, standby, on, pairing, connecting, connected), presence, power, tokenState, modelName, tvName, resolution, os, wifiMac, networkType, lastKey, lastApp, apps, appCount, lastWol
</ul>

=end html
=cut
