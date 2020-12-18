########################################################################################
#
#  ProxmoxVE.pm
#
#  FHEM module to communicate with ProxmoxVE cluster
#  Hubert Becker, 2020
#
#  $Id: 36_ProxmoxVE.pm 20605 2020-11-01 17:46:01Z Carlos $
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later veodersion.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################

package FHEM::ProxmoxVE;

use strict;
use warnings;
use POSIX;

use lib './lib';
use Net::Proxmox::VE;
use Data::Dumper;
use GPUtils qw(GP_Import GP_Export);                              # wird f�r den Import der FHEM Funktionen aus der fhem.pl ben�tigt
use IO::Socket::SSL qw(SSL_VERIFY_NONE);
use JSON;
use HttpUtils;
use MIME::Base64;
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday);
use HttpUtils;
use Encode;

use vars qw{%attr %defs};

sub Log($$);

eval "use FHEM::Meta;1" or my $modMetaAbsent = 1;                 ## no critic 'eval'

# no if $] >= 5.017011, warnings => 'experimental';

# Run before module compilation
BEGIN {
  # Import from main::
  GP_Import(
      qw(
          AnalyzePerlCommand
          asyncOutput
          AttrVal
          BlockingCall
          BlockingKill
          CancelDelayedShutdown
          CommandSet
          CommandAttr
          CommandDelete
          CommandDefine
          CommandGet
          CommandSave
          CommandSetReading
          CommandSetstate
          CommandTrigger
          data
          defs
          devspec2array
          fhemTimeLocal
          FmtDateTime
          FmtTime
          FW_makeImage
          getKeyValue
          HttpUtils_NonblockingGet
          init_done
          InternalTimer
          IsDisabled
          Log3
          modules
          readingFnAttributes
          ReadingsVal
          RemoveInternalTimer
          readingsDelete
          readingsBeginUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsEndUpdate
          readingsSingleUpdate
          ReadingsTimestamp
          sortTopicNum
          setKeyValue
          TimeNow
          secs2human
        )
  );

  # Export to main context with different name
  #     my $pkg  = caller(0);
  #     my $main = $pkg;
  #     $main =~ s/^(?:.+::)?([^:]+)$/main::$1\_/gx;
  #     foreach (@_) {
  #         *{ $main . $_ } = *{ $pkg . '::' . $_ };
  #     }
  GP_Export(
      qw(
          Initialize
        )
  );
}

# Versions History intern
my %vNotesIntern = (
  "1.0.0"  => "06.04.2020  initial "
);

# Versions History extern
my %vNotesExtern = (
  "1.0.0"  => "06.04.2020  initial "
);

#-- globals on start
my $module_version = "0.3.2 Beta";

my $PVE = "";
my $debug    = 0;

########################################################################################
#
# ProxmoxVE_Initialize
#
# Parameter hash
#
########################################################################################
sub Initialize {
 my ($hash) = @_;
 my $sub_name = (caller(0))[3];

 $hash->{DefFn}                 = \&Define;
 $hash->{UndefFn}               = \&Undef;
 $hash->{DeleteFn}              = \&Delete;
 $hash->{SetFn}                 = \&Set;
 $hash->{GetFn}                 = \&Get;
 $hash->{AttrFn}                = \&Attr;
 # $hash->{DelayedShutdownFn}     = \&DelayedShutdown;
 $hash->{AttrList}              = "disable:1,0 " .
					              "interval " .
					              $readingFnAttributes;

  $hash->{Clients}    = ":ProxmoxVENode:";
  $hash->{MatchList}  = {"1:ProxmoxVENode"      => "^ProxmoxVENode"};

  FHEM::Meta::InitMod( __FILE__, $hash ) if(!$modMetaAbsent);  # f�r Meta.pm (https://forum.fhem.de/index.php/topic,97589.0.html)

  return;
}

################################################################
# define myProxmoxVE ProxmoxVE 192.168.2.10
#                   [1]        [2]
#
################################################################
sub Define {
  my ($hash, $def) = @_;
  my $name         = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my @a = split("[ \t][ \t]*", $def);

  return "[ProxmoxVE] Wrong syntax: use define <name> ProxmoxVE <ip> ]" if(int(@a) < 2);
  return "[ProxmoxVE] Invalid IP address ".$a[2]." of Proxmox Cluster"                 if( $a[2] !~ m|\d\d?\d?\.\d\d?\d?\.\d\d?\d?\.\d\d?\d?(\:\d+)?| );

  my $subtype;
  my $name      = $a[0];
  my $host      = $a[2];
  my $interval 	= 300;

  $hash->{HOST}                  = $host;
  $hash->{DEF}                   = "$host";
  $hash->{PVE_VERSION}           = "unknown";
  $hash->{PVE_RELEASE}           = "unknown";
  $hash->{PVE_TYPE}              = "unknown";
  $hash->{VERSION}               = $module_version;
  $hash->{NOTIFYDEV}             = "global,$name";
  $hash->{STATE}                 = "initialized";
  $hash->{HELPER}{MODMETAABSENT} = 1 if($modMetaAbsent);                                                # Modul Meta.pm nicht vorhanden

  CommandAttr(undef,"$name room 01_ProxmoxVE");
  CommandAttr(undef,"$name event-on-update-reading .*");

  # Log3 $name, 4,"[$sub_name] pve: 0:".$a[0]." 1:".$a[1]." 2:".$a[2];

  # Versionsinformationen setzen
  setVersionInfo($hash);

  # Credentials lesen
  getcredentials($hash,1,"credentials");

  readingsBeginUpdate         ($hash);
  # readingsBulkUpdateIfChanged ($hash, "Errorcode"  , "none");
  # readingsBulkUpdateIfChanged ($hash, "Error"      , "none");
  # readingsBulkUpdateIfChanged ($hash, "QueueLength", 0);                     # L�nge Sendqueue initialisieren
  readingsBulkUpdate          ($hash, "nextUpdate" , "Manual");              # Abrufmode initial auf "Manual" setzen
  readingsBulkUpdate          ($hash, "state"      , "Initialized");         # Init state
  readingsEndUpdate           ($hash,1);

  # initiale Routinen nach Start ausf�hren , verz�gerter zuf�lliger Start
  initOnBoot($name);

  # $modules{ProxmoxVE}{defptr}{$hash->{HOST}} = $hash;

  return undef;
}

######################################################################################
#                   initiale Startroutinen nach Restart FHEM
######################################################################################
sub initOnBoot {
  my ($name) = @_;
  my $hash   = $defs{$name};
  my ($ret);

  RemoveInternalTimer($name, "FHEM::ProxmoxVE::initOnBoot");

  if ($init_done) {
      CommandGet(undef, "$name statusRequest");                      # Status initial abrufen
  } else {
      InternalTimer(gettimeofday()+3, "FHEM::ProxmoxVE::initOnBoot", $name, 0);
  }

return;
}

#############################################################################################
#      regelm��iger Intervallabruf
#############################################################################################
sub periodicCall {
  my ($name)   = @_;
  my $hash     = $defs{$name};
  my $interval = AttrVal($name, "interval", 0);
  my $model    = $hash->{MODEL};
  my $new;
  my $sub_name = (caller(0))[3];

  if(!$interval) {
      $hash->{MODE} = "Manual";
  } else {
      $new = gettimeofday()+$interval;
      readingsBeginUpdate ($hash);
      readingsBulkUpdate  ($hash, "nextUpdate", "Automatic - next polltime: ".FmtTime($new));     # Abrufmode initial auf "Manual" setzen
      readingsEndUpdate   ($hash,1);
  }

  RemoveInternalTimer($name,"FHEM::ProxmoxVE::periodicCall");
  return if(!$interval);

  if($hash->{CREDENTIALS} && !IsDisabled($name)) {
      # CommandSet(undef, "$name statusRequest");
      CommandGet(undef, "$name statusRequest");                      # Status initial abrufen
                                                      # Eintr�ge aller gew�hlter Kalender oder Aufgabenlisten abrufen (in Queue stellen)
  }

  InternalTimer($new, "FHEM::ProxmoxVE::periodicCall", $name, 0);

return;
}


################################################################
# Die Undef-Funktion wird aufgerufen wenn ein Ger�t mit delete
# gel�scht wird oder bei der Abarbeitung des Befehls rereadcfg,
# der ebenfalls alle Ger�te l�scht und danach das
# Konfigurationsfile neu einliest.
# Funktion: typische Aufr�umarbeiten wie das
# saubere Schlie�en von Verbindungen oder das Entfernen von
# internen Timern, sofern diese im Modul zum Pollen verwendet
# wurden.
################################################################
sub Undef {
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  delete $data{SSCal}{$name};
  RemoveInternalTimer($name);

return;
}

#################################################################
# Wenn ein Gerät in FHEM gelöscht wird, wird zuerst die Funktion
# X_Undef aufgerufen um offene Verbindungen zu schlie�en,
# anschlie�end wird die Funktion X_Delete aufgerufen.
# Funktion: Aufr�umen von dauerhaften Daten, welche durch das
# Modul evtl. f�r dieses Ger�t spezifisch erstellt worden sind.
# Es geht hier also eher darum, alle Spuren sowohl im laufenden
# FHEM-Prozess, als auch dauerhafte Daten bspw. im physikalischen
# Ger�t zu l�schen die mit dieser Ger�tedefinition zu tun haben.
#################################################################
sub Delete {
  my ($hash, $arg) = @_;
  my $name  = $hash->{NAME};
  my $index = $hash->{TYPE}."_".$hash->{NAME}."_credentials";

  # gespeicherte Credentials l�schen
  setKeyValue($index, undef);

return;
}



#######################################################################################
#
# Proxmox_pve - get pve client
#
# Parameter hash = hash of device addressed
#
#######################################################################################

sub PVE_getPVE ($) {
  my ($hash) = @_;
  my $name     = $hash->{NAME};
  my $host     = $hash->{HOST};
  my $sub_name = (caller(0))[3];

  # Credentials abrufen
  my ($success, $username, $password) = getcredentials($hash,0,"credentials");

  unless ($success) {
    Log3 $name, 2, "$name - Credentials couldn't be obtained successfully - make sure you've set it with \"set $name credentials <username> <password>\"";
    return;
  }

  Log3 $name, 4,"[$sub_name] user: $username pass: $password";

  $PVE = Net::Proxmox::VE->new(
   	  	host     => $host,
        username => $username,
        password => $password,
        debug    => $debug,
        realm    => "pam",
        ssl_opts => {
           SSL_verify_mode => SSL_VERIFY_NONE,
           verify_hostname => 0
        },
  );

  return "[ProxmoxVE] login failed $host $username $password" if (! $PVE->login);
  return "[ProxmoxVE] invalid login ticket" if (! $PVE->check_login_ticket);
  return "[ProxmoxVE] unsupport api version" if (! $PVE->api_version_check);

  $hash->{PVE} = $PVE;
  $hash->{HELPER}->{PVE} = $PVE;

  return ($PVE);
}

################################################################
sub Attr {                                                  ## no critic 'complexity'
    my ($cmd,$name,$aName,$aVal) = @_;
    my $hash  = $defs{$name};
    my $model = $hash->{MODEL};
    my ($do,$val);

    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value

    if ($cmd eq "set") {

        my $attrVal = $aVal;

        if ($attrVal =~ m/^\{.*\}$/xs && $attrVal =~ m/=>/x) {
            $attrVal =~ s/\@/\\\@/gx;
            $attrVal =~ s/\$/\\\$/gx;

            my $av = eval $attrVal;                                       ## no critic 'eval'
            if($@) {
                Log3($name, 2, "$name - Error while evaluate: ".$@);
                return $@;
            } else {
                $attrVal = $av if(ref($av) eq "HASH");
            }
        }
        $hash->{HELPER}{$aName} = $attrVal;
    } else {
        delete $hash->{HELPER}{$aName};
    }

    if ($aName eq "disable") {
        if($cmd eq "set") {
            $do = $aVal?1:0;
        }
        $do  = 0 if($cmd eq "del");

        $val = ($do == 1 ? "disabled" : "initialized");

        if ($do == 1) {
            RemoveInternalTimer($name);
        } else {
            InternalTimer(gettimeofday()+2, "FHEM::ProxmoxVE::initOnBoot", $name, 0) if($init_done);
        }

        readingsBeginUpdate($hash);
        readingsBulkUpdate ($hash, "state", $val);
        readingsEndUpdate  ($hash,1);
    }

    if ($cmd eq "set") {
        if ($aName =~ m/timeout|cutLaterDays|cutOlderDays|interval/x) {
            unless ($aVal =~ /^\d+$/x) { return qq{The value of $aName is not valid. Use only integers 1-9 !}; }
        }
        if($aName =~ m/interval/x) {
            RemoveInternalTimer($name,"FHEM::ProxmoxVE::periodicCall");
            if($aVal > 0) {
                InternalTimer(gettimeofday()+1.0, "FHEM::ProxmoxVE::periodicCall", $name, 0);
            }
        }
    }

return;
}

########################################################################################
#
# Set - Implements SetFn function
#
# Parameter hash, a = argument array
#
########################################################################################
sub Set {                                                    ## no critic 'complexity'
  my ($hash, @a) = @_;
  my $sub_name = (caller(0))[3];

  return "\"set X\" needs at least an argument" if ( @a < 2 );
  my $name    = $a[0];
  my $opt     = $a[1];
  my $prop    = $a[2];
  my $prop1   = $a[3];
  my $prop2   = $a[4];
  my $prop3   = $a[5];
  my $model   = $hash->{MODEL};

  my ($success,$setlist);

  return if(IsDisabled($name));

  if(!$hash->{CREDENTIALS}) {
      # initiale setlist f�r neue Devices
      $setlist = "Unknown argument $opt, choose one of ". "credentials ";
  } else {                                                                      # Model Aufgabenliste
      $setlist = "Unknown argument $opt, choose one of ".
                 "credentials ".
                 "eraseReadings:noArg ".
                 "listSendqueue:noArg ".
                 "logout:noArg ".
                 "restartSendqueue:noArg "
                 ;
  }

  if ($opt eq "credentials") {
      return "The command \"$opt\" needs an argument." if (!$prop);
      ($success) = setcredentials($hash,$prop,$prop1);

	  if($success) {
          PVE_getPVE($hash);

          return "credentials saved successfully";
	  } else {
          return "Error while saving credentials - see logfile for details";
	  }

  } elsif ($opt eq 'eraseReadings') {
        delReadings($name,0);                                                    # Readings l�schen

  } else {
      return "$setlist";
  }

return;
}

################################################################
sub Get {                                                                       ## no critic 'complexity'
    my ($hash, @a) = @_;
    my $sub_name = (caller(0))[3];
    return "\"get X\" needs at least an argument" if ( @a < 2 );
    my $name = shift @a;
    my $opt  = shift @a;
    my $arg  = shift @a;
    my $arg1 = shift @a;
    my $arg2 = shift @a;
    my $ret = "";
    my $getlist;

    if(!$hash->{CREDENTIALS}) {
        return;
  } else {
	$getlist = "Unknown argument $opt, choose one of ".
               "statusRequest:noArg ".
               "Autocreate:noArg " .
               "Node:noArg " .
               "Container:noArg " .
               "VM:noArg " .
               "Storage:noArg " .
    		   "storedCredentials:noArg "
               ;
  }

  return if(IsDisabled($name));

  if ($opt eq "storedCredentials") {
    if (!$hash->{CREDENTIALS}) {return "Credentials of $name are not set - make sure you've set it with \"set $name credentials <CREDENTIALS>\"";}
      # Credentials abrufen
      my ($success, $username, $passwd) = getcredentials($hash,0,"credentials");
      unless ($success) {return "Credentials couldn't be retrieved successfully - see logfile"};

      return "Stored Credentials:\n".
             "===================\n".
             "Username: $username, Password: $passwd \n"
             ;
    } elsif ($opt eq "statusRequest") {
        PVE_getPVE($hash);
        ProxmoxVE_getClusterStatus($hash);
        return undef;
    } elsif ($opt eq "Autocreate") {
     		ProxmoxVE_AutoCreate($hash);
    		return undef;
    } elsif ($opt eq "Node") {
      my $items     = PVE_getNodes($hash);
      my $ret = "";
      foreach my $item( @$items ) {
        $ret = $ret ."ID: " . $item->{id} . "\t Node: " . $item->{node} . "\t Status: " . $item->{status}. "\n";
      }
      return $ret;
    } elsif ($opt eq "Container") {
      my $items     = PVE_getContainer($hash);
      my $ret = "";
      foreach my $item( @$items ) {
        $ret = $ret ."ID: " . $item->{id} . "\t Name: " . $item->{name} . "\t Node: " . $item->{node} . "\t Status: " . $item->{status} . "\n";
      }
      return $ret;
    } elsif ($opt eq "VM") {
      my $items     = PVE_getVM($hash);
      my $ret = "";
      foreach my $item( @$items ) {
        $ret = $ret ."ID: " . $item->{id} . "\t Name: " . $item->{name} . "\t Node: " . $item->{node} . "\t Status: " . $item->{status} . "\n";
      }
      return $ret;
    } elsif ($opt eq "Storage") {
      my $items     = PVE_getStorage($hash);
      my $ret = "";
      foreach my $item( @$items ) {
        $ret = $ret ."ID: " . $item->{id} . "\t Storage: " . $item->{storage} . "\t Status: " . $item->{status} . "\n";
      }
      return $ret;
    } else {
        return "$getlist";
	}

  return $ret;                                                        # not generate trigger out of command
}

sub PVE_getClusterStatus($) {
    my ($hash) = @_;
   	my $name = $hash->{NAME};
    my $sub_name = (caller(0))[3];

    # my $cluster = $PVE->get_cluster_status();
    my $cluster = $PVE->get('/cluster/status');
    # Log3 $name, 4,"[$sub_name]: " . Dumper(encode_json($cluster));
    return $cluster;
}

sub PVE_getVersion($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $version =  $PVE->get('/version');

  return $version;
}

sub ProxmoxVE_getClusterStatus($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  Log3 $name, 4,"[$sub_name] begin";

  my $cluster = PVE_getClusterStatus($hash) ;
  # Log3 $name, 4,"[$sub_name] cluster: " . Dumper(encode_json($cluster));

  my $version = PVE_getVersion($hash);
  # Log3 $name, 4,"[$sub_name] version: " . Dumper(encode_json($version));

  my $nodes   = PVE_getNode($hash);
  my $lxc     = PVE_getContainer($hash);
  my $qemu    = PVE_getVM($hash);
  my $storage = PVE_getStorage($hash);

  $hash->{PVE_VERSION} = $version->{version};
  $hash->{PVE_RELEASE} = $version->{release};

  my $lxcnr = scalar @$lxc;
  my $qemunr = scalar @$qemu;
  my $storagenr = scalar @$storage;


  my $mycluster = "";
  foreach my $item( @$cluster ) {
     if ($item->{type} eq "cluster") {
        Log3 $name, 4,"[$sub_name] Cluster: " . $item->{id} . " " . $item->{name};
        $mycluster = $item;
     }
  }

  readingsBeginUpdate($hash);
  readingsSingleUpdate($hash,"id",$mycluster->{id}, "N/A");
  readingsSingleUpdate($hash,"name",$mycluster->{name}, "N/A");
  readingsSingleUpdate($hash,"type",$mycluster->{type}, "N/A");
  readingsSingleUpdate($hash,"nodes",$mycluster->{nodes}, "N/A");

  $hash->{PVE_TYPE}    = $mycluster->{type};
  $hash->{SUBTYPE}     = $mycluster->{type};
  $hash->{STATE}       = "connected";

  readingsSingleUpdate($hash,"container",$lxcnr,"N/A");
  readingsSingleUpdate($hash,"virtualmachines",$qemunr,"N/A");
  readingsSingleUpdate($hash,"storage",$storagenr,"N/A");
  readingsSingleUpdate($hash,"version",$version->{version},"N/A");
  readingsSingleUpdate($hash,"release",$version->{release},"N/A");
  readingsSingleUpdate($hash,"state", "connected","N/A" );
  readingsSingleUpdate($hash,"state", "connected","N/A" );
  readingsEndUpdate($hash,1);
  CommandAttr(undef, $name . " stateFormat Status: state Container: container VMs: virtualmachines Storage: storage");
}

sub PVE_getNodes($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $nodes = $PVE->get('/nodes');

  return $nodes;
}

sub PVE_getContainer($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my %args = (type => 'vm');
  my $resources = $PVE->get_cluster_resources(%args);
  # my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "lxc";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getVM($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "qemu";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getStorage($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "storage";

    push( @devices, $item );
  }
  return \@devices;
}

sub ProxmoxVE_AutoCreate($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  Log3 $name, 4,"[$sub_name] begin";

  # my $resources = PVE_getNodes($hash);
  my $resources = PVE_getResources($hash);

  foreach my $resource (@{$resources}) {
    if ($resource->{type} eq "node")  {
      ProxmoxVE_definenode($hash,$resource);
    } elsif ($resource->{type} eq "qemu")  {
      ProxmoxVE_defineqemu($hash,$resource);
    } elsif ($resource->{type} eq "lxc")  {
      ProxmoxVE_definelxc($hash,$resource);
    } elsif ($resource->{type} eq "storage")  {
      # ProxmoxVE_definestorage($hash,$resource);
    }
  }
  Log3 $name, 4,"[$sub_name] end";
}

sub ProxmoxVE_definenode($$) {
  my ($hash, $resource) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  Log3 $name, 1,"[$sub_name] begin";

  my @ids = split /\//, $resource->{id};

  my $type = $resource->{type};
  my $node = $resource->{node};
  my $id   = $ids[@ids-1];

  my $devname = "N_". $id;
  my $define= "$devname ProxmoxVENode  $resource->{id} $id";
  Log3 $name, 4,"[$sub_name] DEFINE: " . $define;

#    if( defined($modules{$hash->{TYPE}}{defptr}{"N_$id}"}) ) {
#      my $d = $modules{$hash->{TYPE}}{defptr}{"N_$id}"};
#      $d->{association} = $resource->{association} if($resource->{association});
#
#      Log3 $name, 4,"[$sub_name] $name: device '$resource->{id}' already defined as $d->{NAME}" if( defined($d) && $d->{NAME} ne $name );
#      next;
#    }



  Log3 $name, 4,"[$sub_name] create new device '$devname' for device '$id'";

  my $cmdret= CommandDefine(undef,$define);
  if($cmdret) {
    Log3 $name, 4,"[$sub_name] Autocreate: An error occurred while creating device for id '$id': $cmdret";
  } else {
    $cmdret= CommandSetstate(undef, "$devname $resource->{status}");

    $cmdret= CommandAttr(undef,"$devname room 01_ProxmoxVE");
    $cmdret= CommandAttr(undef,"$devname IODev $name");
    $cmdret= CommandAttr(undef,"$devname group $resource->{node}");
    $cmdret= CommandAttr(undef,"$devname devStateIcon online:10px-kreis-gruen\@green stopped:10px-kreis-rot\@red");
    $cmdret= CommandAttr(undef,"$devname alias $resource->{node}($resource->{id})");

    $cmdret= CommandAttr(undef,"$devname icon solid/server");
    $cmdret= CommandAttr(undef,"$devname webCmd start:stop:reboot:shutdown");

    $cmdret= CommandSetReading(undef, "$devname .associatedWith $name");
    $cmdret= CommandSetReading(undef, "$devname cpu $resource->{cpu}");
    $cmdret= CommandSetReading(undef, "$devname disk $resource->{disk}");
    $cmdret= CommandSetReading(undef, "$devname id $resource->{id}");
    $cmdret= CommandSetReading(undef, "$devname maxcpu $resource->{maxcpu}");
    $cmdret= CommandSetReading(undef, "$devname maxdisk $resource->{maxdisk}");
    $cmdret= CommandSetReading(undef, "$devname maxmem $resource->{maxmem}");
    $cmdret= CommandSetReading(undef, "$devname mem $resource->{mem}");
    $cmdret= CommandSetReading(undef, "$devname node $resource->{node}");
    $cmdret= CommandSetReading(undef, "$devname status $resource->{status}");
    $cmdret= CommandSetReading(undef, "$devname type $resource->{type}");
    $cmdret= CommandSetReading(undef, "$devname uptime " .  secs2human($resource->{uptime}));

  }
  CommandSave(undef,undef);

  Log3 $name, 4,"[$sub_name] end";

  return undef;
}

sub ProxmoxVE_defineqemu($$) {
  my ($hash, $resource) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my @ids = split /\//, $resource->{id};

  my $type = $resource->{type};
  my $node = $resource->{node};
  my $id   = $ids[@ids-1];

  my $devname = "N_". $id;
  my $define= "$devname ProxmoxVENode  $resource->{id} $id";
  Log3 $name, 4,"[$sub_name] DEFINE: " . $define;

  Log3 $name, 1, "$name: create new device '$devname' for device '$id'";
  my $cmdret= CommandDefine(undef,$define);
  if($cmdret) {
    Log3 $name, 1,"[$sub_name] Autocreate: An error occurred while creating device for id '$id': $cmdret";
  } else {
    $cmdret= CommandSetstate(undef, "$devname $resource->{status}");

    $cmdret= CommandAttr(undef,"$devname room 01_ProxmoxVE");
    $cmdret= CommandAttr(undef,"$devname IODev $name");
    $cmdret= CommandAttr(undef,"$devname group $resource->{node}");
    $cmdret= CommandAttr(undef,"$devname devStateIcon running:10px-kreis-gruen\@green stopped:10px-kreis-rot\@red");
    $cmdret= CommandAttr(undef,"$devname alias $resource->{name}($resource->{id})");

    $cmdret= CommandAttr(undef,"$devname icon icon-display");
    $cmdret= CommandAttr(undef,"$devname webCmd start:stop:reboot:shutdown");

    $cmdret= CommandSetReading(undef, "$devname .associatedWith $name");

    $cmdret= CommandSetReading(undef, "$devname cpu $resource->{cpu}");
    $cmdret= CommandSetReading(undef, "$devname disk $resource->{disk}");
    $cmdret= CommandSetReading(undef, "$devname diskread $resource->{diskread}");
    $cmdret= CommandSetReading(undef, "$devname diskwrite $resource->{diskwrite}");
    $cmdret= CommandSetReading(undef, "$devname id $resource->{id}");
    $cmdret= CommandSetReading(undef, "$devname maxcpu $resource->{maxcpu}");
    $cmdret= CommandSetReading(undef, "$devname maxdisk $resource->{maxdisk}");
    $cmdret= CommandSetReading(undef, "$devname maxmem $resource->{maxmem}");
    $cmdret= CommandSetReading(undef, "$devname mem $resource->{mem}");
    $cmdret= CommandSetReading(undef, "$devname name $resource->{name}");
    $cmdret= CommandSetReading(undef, "$devname netin $resource->{netin}");
    $cmdret= CommandSetReading(undef, "$devname netout $resource->{netout}");
    $cmdret= CommandSetReading(undef, "$devname node $resource->{node}");
    $cmdret= CommandSetReading(undef, "$devname status $resource->{status}");
    $cmdret= CommandSetReading(undef, "$devname template $resource->{template}");
    $cmdret= CommandSetReading(undef, "$devname type $resource->{type}");
    $cmdret= CommandSetReading(undef, "$devname uptime " .  secs2human($resource->{uptime}));
    $cmdret= CommandSetReading(undef, "$devname vmid $resource->{vmid}");

  }
  CommandSave(undef,undef);

  return undef;
}

sub ProxmoxVE_definelxc($$) {
  my ($hash, $resource) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my @ids = split /\//, $resource->{id};

  my $type = $resource->{type};
  my $node = $resource->{node};
  my $id   = $ids[@ids-1];

  my $devname = "N_". $id;
  my $define= "$devname ProxmoxVENode  $resource->{id} $id";
  Log3 $name, 1,"[$sub_name] DEFINE: " . $define;

  Log3 $name, 2, "$name: create new device '$devname' for device '$id'";
  my $cmdret= CommandDefine(undef,$define);
  if($cmdret) {
    Log3 $name, 1,"[$sub_name] Autocreate: An error occurred while creating device for id '$id': $cmdret";
  } else {
    $cmdret= CommandSetstate(undef, "$devname $resource->{status}");

    $cmdret= CommandAttr(undef,"$devname room 01_ProxmoxVE");
    $cmdret= CommandAttr(undef,"$devname IODev $name");
    $cmdret= CommandAttr(undef,"$devname group $resource->{node}");
    $cmdret= CommandAttr(undef,"$devname devStateIcon running:10px-kreis-gruen\@green stopped:10px-kreis-rot\@red");
    $cmdret= CommandAttr(undef,"$devname alias $resource->{name}($resource->{id})");

    $cmdret= CommandAttr(undef,"$devname icon solid/cube");
    $cmdret= CommandAttr(undef,"$devname webCmd start:stop:reboot:shutdown");

    $cmdret= CommandSetReading(undef, "$devname .associatedWith $name");

    $cmdret= CommandSetReading(undef, "$devname cpu $resource->{cpu}");
    $cmdret= CommandSetReading(undef, "$devname disk $resource->{disk}");
    $cmdret= CommandSetReading(undef, "$devname diskread $resource->{diskread}");
    $cmdret= CommandSetReading(undef, "$devname diskwrite $resource->{diskwrite}");
    $cmdret= CommandSetReading(undef, "$devname id $resource->{id}");
    $cmdret= CommandSetReading(undef, "$devname maxcpu $resource->{maxcpu}");
    $cmdret= CommandSetReading(undef, "$devname maxdisk $resource->{maxdisk}");
    $cmdret= CommandSetReading(undef, "$devname maxmem $resource->{maxmem}");
    $cmdret= CommandSetReading(undef, "$devname mem $resource->{mem}");
    $cmdret= CommandSetReading(undef, "$devname name $resource->{name}");
    $cmdret= CommandSetReading(undef, "$devname netin $resource->{netin}");
    $cmdret= CommandSetReading(undef, "$devname netout $resource->{netout}");
    $cmdret= CommandSetReading(undef, "$devname node $resource->{node}");
    $cmdret= CommandSetReading(undef, "$devname status $resource->{status}");
    $cmdret= CommandSetReading(undef, "$devname template $resource->{template}");
    $cmdret= CommandSetReading(undef, "$devname type $resource->{type}");
    $cmdret= CommandSetReading(undef, "$devname uptime " . secs2human($resource->{uptime}));
    $cmdret= CommandSetReading(undef, "$devname vmid $resource->{vmid}");

  }
  CommandSave(undef,undef);

  return undef;
}

sub ProxmoxVE_definestorage($$) {
  my ($hash, $resource) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my @ids = split /\//, $resource->{id};

  my $type = $resource->{type};
  my $node = $resource->{node};
  my $id   = $ids[@ids-1];

  my $devname = "N_". $id;
  my $define= "$devname ProxmoxVENode  $resource->{id} $id";
  Log3 $name, 1,"[$sub_name] DEFINE: " . $define;

  Log3 $name, 2, "$name: create new device '$devname' for device '$id'";
  my $cmdret= CommandDefine(undef,$define);
  if($cmdret) {
    Log3 $name, 1,"[$sub_name] Autocreate: An error occurred while creating device for id '$id': $cmdret";
  } else {
    $cmdret= CommandSetstate(undef, "$devname $resource->{status}");

    $cmdret= CommandAttr(undef,"$devname room 01_ProxmoxVE");
    $cmdret= CommandAttr(undef,"$devname IODev $name");
    $cmdret= CommandAttr(undef,"$devname group $resource->{node}");
    $cmdret= CommandAttr(undef,"$devname devStateIcon available:10px-kreis-gruen\@green stopped:10px-kreis-rot\@red");
    $cmdret= CommandAttr(undef,"$devname alias $resource->{storage}($resource->{id})");
    $cmdret= CommandAttr(undef,"$devname icon im_storage");

    $cmdret= CommandSetReading(undef, "$devname .associatedWith $name");
    $cmdret= CommandSetReading(undef, "$devname disk $resource->{disk}");
    $cmdret= CommandSetReading(undef, "$devname id $resource->{id}");
    $cmdret= CommandSetReading(undef, "$devname maxdisk $resource->{maxdisk}");
    $cmdret= CommandSetReading(undef, "$devname node $resource->{node}");
    $cmdret= CommandSetReading(undef, "$devname status $resource->{status}");
    $cmdret= CommandSetReading(undef, "$devname storage $resource->{storage}");
    $cmdret= CommandSetReading(undef, "$devname type $resource->{type}");
  }
  CommandSave(undef,undef);

  return undef;
}


sub PVE_getNodes($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $nodes = $PVE->get('/nodes');

  return $nodes;
}

sub PVE_getNode($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my %args = (type => 'vm');
  my $resources = $PVE->get_cluster_resources(%args);
  # my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "node";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getContainer($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my %args = (type => 'vm');
  my $resources = $PVE->get_cluster_resources(%args);
  # my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "lxc";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getContainerbyNode($$) {
  my ($hash,$node) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];
  Log3 $name, 4,"[$sub_name] $name nodename: $node";

  my $resources = $PVE->get('/nodes/'.$node.'/lxc');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "lxc";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getVM($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "qemu";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getVMbyNode($$) {
  my ($hash,$node) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/nodes/'.$node.'/qemu');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "qemu";

    push( @devices, $item );
  }

  return \@devices;
}

sub PVE_getStorage($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/cluster/resources');

  my @devices = ();
  foreach my $item( @$resources ) {
    next unless $item->{type} eq "storage";

    push( @devices, $item );
  }
  return \@devices;
}

sub PVE_getResources($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $resources = $PVE->get('/cluster/resources');
  return $resources;
}

################################################################
#    alle Readings au�er excludierte l�schen
#    $respts -> Respect Timestamp
#               wenn gesetzt, wird Reading nicht gel�scht
#               wenn Updatezeit identisch zu "lastUpdate"
################################################################
sub delReadings {
  my ($name,$respts) = @_;
  my ($lu,$rts,$excl);

  $excl  = "Error|Errorcode|QueueLength|state|nextUpdate";
  $excl .= "|lastUpdate" if($respts);

  my @allrds = keys%{$defs{$name}{READINGS}};
  for my $key(@allrds) {
      if($respts) {
          $lu  = $data{SSCal}{$name}{lastUpdate};
          $rts = ReadingsTimestamp($name, $key, $lu);
          next if($rts eq $lu);
      }
      delete($defs{$name}{READINGS}{$key}) if($key !~ m/^$excl$/x);
  }

return;
}


#############################################################################################
#                          Versionierungen des Moduls setzen
#                  Die Verwendung von Meta.pm und Packages wird ber�cksichtigt
#############################################################################################
sub setVersionInfo {
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  my $v                    = (sortTopicNum("desc",keys %vNotesIntern))[0];
  my $type                 = $hash->{TYPE};
  $hash->{HELPER}{PACKAGE} = __PACKAGE__;
  $hash->{HELPER}{VERSION} = $v;

  if($modules{$type}{META}{x_prereqs_src} && !$hash->{HELPER}{MODMETAABSENT}) {
      # META-Daten sind vorhanden
      $modules{$type}{META}{version} = "v".$v;                                        # Version aus META.json �berschreiben, Anzeige mit {Dumper $modules{SSCal}{META}}
      if($modules{$type}{META}{x_version}) {                                          # {x_version} ( nur gesetzt wenn $Id: 57_SSCal.pm 22019 2020-05-24 06:59:27Z DS_Starter $ im Kopf komplett! vorhanden )
          $modules{$type}{META}{x_version} =~ s/1\.1\.1/$v/gx;
      } else {
          $modules{$type}{META}{x_version} = $v;
      }
      return $@ unless (FHEM::Meta::SetInternals($hash));                             # FVERSION wird gesetzt ( nur gesetzt wenn $Id: 57_SSCal.pm 22019 2020-05-24 06:59:27Z DS_Starter $ im Kopf komplett! vorhanden )
      if(__PACKAGE__ eq "FHEM::$type" || __PACKAGE__ eq $type) {
          # es wird mit Packages gearbeitet -> Perl �bliche Modulversion setzen
          # mit {<Modul>->VERSION()} im FHEMWEB kann Modulversion abgefragt werden
          use version 0.77; our $VERSION = FHEM::Meta::Get( $hash, 'version' );       ## no critic 'VERSION'
      }
  } else {
      # herk�mmliche Modulstruktur
      $hash->{VERSION} = $v;
  }

return;
}

######################################################################################
#                            credentials speichern
######################################################################################
sub setcredentials {
    my ($hash, @credentials) = @_;
    my $name                 = $hash->{NAME};
    my ($success, $credstr, $username, $passwd, $index, $retcode);
    my (@key,$len,$i);

    my $ao   = "credentials";
    $credstr = encode_base64(join('!_ESC_!', @credentials));

    # Beginn Scramble-Routine
    @key = qw(1 3 4 5 6 3 2 1 9);
    $len = scalar @key;
    $i = 0;
    $credstr = join "", map { $i = ($i + 1) % $len; chr((ord($_) + $key[$i]) % 256) } split //, $credstr;
    # End Scramble-Routine

    $index   = $hash->{TYPE}."_".$hash->{NAME}."_".$ao;
    $retcode = setKeyValue($index, $credstr);

    if ($retcode) {
        Log3($name, 2, "$name - Error while saving Credentials - $retcode");
        $success = 0;
    } else {
        ($success, $username, $passwd) = getcredentials($hash,1,$ao);        # Credentials nach Speicherung lesen und in RAM laden ($boot=1)
    }

return ($success);
}

######################################################################################
#                             credentials lesen
######################################################################################
sub getcredentials {
    my ($hash,$boot, $ao) = @_;
    my $name              = $hash->{NAME};
    my ($success, $username, $passwd, $index, $retcode, $credstr);
    my (@key,$len,$i);

    if ($boot) {
        # mit $boot=1 credentials von Platte lesen und als scrambled-String in RAM legen
        $index               = $hash->{TYPE}."_".$hash->{NAME}."_".$ao;
        ($retcode, $credstr) = getKeyValue($index);

        if ($retcode) {
            Log3($name, 2, "$name - Unable to read credentials from file: $retcode");
            $success = 0;
        }

        if ($credstr) {
            # beim Boot scrambled credentials in den RAM laden
            $hash->{HELPER}{CREDENTIALS} = $credstr;

            # "CREDENTIALS" wird als Statusbit ausgewertet. Wenn nicht gesetzt -> Warnmeldung und keine weitere Verarbeitung
            $hash->{CREDENTIALS} = "Set";
            $success = 1;
        }

    } else {
        # boot = 0 -> credentials aus RAM lesen, decoden und zur�ckgeben
        $credstr = $hash->{HELPER}{CREDENTIALS};

        if($credstr) {
            # Beginn Descramble-Routine
            @key = qw(1 3 4 5 6 3 2 1 9);
            $len = scalar @key;
            $i = 0;
            $credstr = join "",
            map { $i = ($i + 1) % $len; chr((ord($_) - $key[$i] + 256) % 256) } split //, $credstr;
            # Ende Descramble-Routine

            ($username, $passwd) = split("!_ESC_!",decode_base64($credstr));

            my $logcre = AttrVal($name, "showPassInLog", "0") == 1 ? $passwd : "********";

            Log3($name, 4, "$name - credentials read from RAM: $username $logcre");

        } else {
            Log3($name, 2, "$name - credentials not set in RAM !");
        }

        $success = (defined($passwd)) ? 1 : 0;
    }

return ($success, $username, $passwd);
}



1;

=pod
=item device
=item summary to communicate with ProxmoxVE
=begin html

<a name="ProxmoxVE"></a>
<h3>ProxmoxVE</h3>
<ul>
        <p> FHEM module to communicate with ProxmoxVE</p>
        <a name="ProxmoxVEdefine" id="ProxmoxVEdefine"></a>
        <h4>Define</h4>
        <p>
            <code>define &lt;name&gt; ProxmoxVE &lt;IP address&gt;</code>
            <br />Defines the ProxmoxVE device. </p>
        Notes: <ul>
         <li>The attribute <code>model</code> <b>must</b> be set</li>
         <li>This module needs the JSON package</li>
         <li>In Shelly switch devices or the Shelly dimmer device one may set URL values that are "hit" when the input or output status changes. Here one must set
           <ul>
           <li> For <i>Button switched ON url</i>: http://&lt;FHEM IP address&gt;:&lt;Port&gt;/fhem?XHR=1&cmd=set%20&lt;Devicename&gt;%20<b>button_on</b>%20[&lt;channel&gt;]</li>
           <li> For <i>Button switched OFF url</i>: http://&lt;FHEM IP address&gt;:&lt;Port&gt;/fhem?XHR=1&cmd=set%20&lt;Devicename&gt;%20<b>button_off</b>%20[&lt;channel&gt;]</li>
           <li> For <i>Output switched ON url</i>: http://&lt;FHEM IP address&gt;:&lt;Port&gt;/fhem?XHR=1&cmd=set%20&lt;Devicename&gt;%20<b>out_on</b>%20[&lt;channel&gt;]</li>
           <li> For <i>Output switched OFF url</i>: http://&lt;FHEM IP address&gt;:&lt;Port&gt;/fhem?XHR=1&cmd=set%20&lt;Devicename&gt;%20<b>out_off</b>%20[&lt;channel&gt;]</li>
           </ul>
           Attention: Of course, a csrfToken must be included as well - or a proper <i>allowed</i> device declared.</li>
         </ul>
        <a name="Shellyset" id="Shellyset"></a>
        <h4>Set</h4>
        For all Shelly devices
        <ul>
        <li><code>set &lt;name&gt; config &lt;registername&gt; &lt;value&gt; [&lt;channel&gt;] </code>
                <br />set the value of a configuration register</li>
        <li>password &lt;password&gt;<br>This is the only way to set the password for the Shelly web interface</li>
        </ul>
        For Shelly switching devices (model=shelly1|shelly1pm|shelly4|shellyplug or (model=shelly2/2.5 and mode=relay))
        <ul>
            <li>
                <code>set &lt;name&gt; on|off|toggle  [&lt;channel&gt;] </code>
                <br />switches channel &lt;channel&gt; on or off. Channel numbers are 0 and 1 for model=shelly2/2.5, 0..3 for model=shelly4. If the channel parameter is omitted, the module will switch the channel defined in the defchannel attribute.</li>
            <li>
                <code>set &lt;name&gt; on-for-timer|off-for-timer &lt;time&gt; [&lt;channel&gt;] </code>
                <br />switches &lt;channel&gt; on or off for &lt;time&gt; seconds. Channel numbers are 0 and 1 for model=shelly2/2.5, and 0..3 model=shelly4.  If the channel parameter is omitted, the module will switch the channel defined in the defchannel attribute.</li>
            <li>
                <code>set &lt;name&gt; xtrachannels </code>
                <br />create <i>readingsProxy</i> devices for switching device with more than one channel</li>

        </ul>
        <br/>For Shelly roller blind devices (model=shelly2/2.5 and mode=roller)
        <ul>
            <li>
                <code>set &lt;name&gt; open|closed|stop </code>
                <br />drives the roller blind open, closed or to a stop.</li>
            <li>
                <code>set &lt;name&gt; pct &lt;integer percent value&gt; </code>
                <br />drives the roller blind to a partially closed position (100=open, 0=closed)</li>
            <li>
                <code>set &lt;name&gt; zero </code>
                <br />calibration of roller device (only for model=shelly2/2.5)</li>
        </ul>
        <br/>For Shelly dimmer devices model=shellydimmer or (model=shellyrgbw and mode=white)
        <ul>
            <li>
               <code>set &lt;name&gt; on|off  [&lt;channel&gt;] </code>
                <br />switches channel &lt;channel&gt; on or off. Channel numbers are 0..3 for model=shellyrgbw. If the channel parameter is omitted, the module will switch the channel defined in the defchannel attribute.</li>
            <li>
                <code>set &lt;name&gt; on-for-timer|off-for-timer &lt;time&gt; [&lt;channel&gt;] </code>
                <br />switches &lt;channel&gt; on or off for &lt;time&gt; seconds. Channel numbers 0..3 for model=shellyrgbw.  If the channel parameter is omitted, the module will switch the channel defined in the defchannel attribute.</li>
            <li>
                <code>set &lt;name&gt; pct &lt;0..100&gt; [&lt;channel&gt;] </code>
                <br />percent value to set brightness value. Channel numbers 0..3 for model=shellyrgbw.  If the channel parameter is omitted, the module will dim the channel defined in the defchannel attribute.</li>
        </ul>
        <br/>For Shelly RGBW devices (model=shellyrgbw and mode=color)
        <ul>
            <li>
               <code>set &lt;name&gt; on|off</code>
                <br />switches device &lt;channel&gt; on or off</li>
            <li>
                <code>set &lt;name&gt; on-for-timer|off-for-timer &lt;time&gt;</code>
                <br />switches device on or off for &lt;time&gt; seconds. </li>
            <li>
                <code>set &lt;name&gt; hsv &lt;hue value 0..360&gt;,&lt;saturation value 0..1&gt;,&lt;brightness value 0..1&gt; </code>
                <br />comma separated list of hue, saturation and value to set the color</li>
            <li>
                <code>set &lt;name&gt; rgb &lt;rrggbb&gt; </code>
                <br />6-digit hex string to set the color</li>
            <li>
                <code>set &lt;name&gt; rgbw &lt;rrggbbww&gt; </code>
                <br />8-digit hex string to set the color and white value</li>
            <li>
                <code>set &lt;name&gt; white &lt;integer&gt;</code>
                <br /> number 0..255 to set the white value</li>
        </ul>
        <a name="Shellyget" id="Shellyget"></a>
        <h4>Get</h4>
        <ul>
            <li>
                <code>get &lt;name&gt; config &lt;registername&gt; [&lt;channel&gt;]</code>
                <br />get the value of a configuration register and writes it in reading config</li>
            <li>
                <code>get &lt;name&gt; registers</code>
                <br />displays the names of the configuration registers for this device</li>
            <li>
                <code>get &lt;name&gt; status</code>
                <br />returns the current devices status.</li>
            <li>
                <code>get &lt;name&gt; version</code>
                <br />display the version of the module</li>
        </ul>
        <a name="Shellyattr" id="Shellyattr"></a>
        <h4>Attributes</h4>
        <ul>
            <li><code>attr &lt;name&gt; shellyuser &lt;shellyuser&gt;</code><br>username for addressing the Shelly web interface</li>
            <li><<code>attr &lt;name&gt; model shelly1|shelly1pm|shelly2|shelly2.5|shelly4|shellyplug|shellydimmer|shellyrgbw </code>
                <br />type of the Shelly device</li>
            <li><code>attr &lt;name&gt; mode relay|roller (only for model=shelly2/2.5) mode white|color (only for model=shellyrgbw)</code>
                <br />type of the Shelly device</li>
             <li>
                <code>&lt;interval&gt;</code>
                <br />Update interval for reading in seconds. The default is 60 seconds, a value of 0 disables the automatic update. </li>
        </ul>
        <br/>For Shelly switching devices (mode=relay for model=shelly2/2.5, standard for all other switching models)
        <ul>
        <li><code>attr &lt;name&gt; defchannel <integer> </code>
                <br />only for model=shelly2|shelly2.5|shelly4 or multi-channel switches: Which channel will be switched, if a command is received without channel number</li>
        </ul>
        <br/>For Shelly roller blind devices (mode=roller for model=shelly2/2.5)
        <ul>
            <li><code>attr &lt;name&gt; maxtime &lt;float&gt; </code>
                <br />time needed for a complete drive upward or downward</li>
            <li><code>attr &lt;name&gt; pct100 open|closed (default:open) </code>
                <br />is pct=100 open or closed ? </li>
        </ul>
        <br/>Standard attributes
        <ul>
            <li><a href="#alias">alias</a>, <a href="#comment">comment</a>, <a
                    href="#event-on-update-reading">event-on-update-reading</a>, <a
                    href="#event-on-change-reading">event-on-change-reading</a>, <a href="#room"
                    >room</a>, <a href="#eventMap">eventMap</a>, <a href="#loglevel">loglevel</a>,
                    <a href="#webCmd">webCmd</a></li>
        </ul>
        </ul>
=end html
=begin html_DE

<a name="Shelly"></a>
<h3>Shelly</h3>
<ul>
Absichtlich keine deutsche Dokumentation vorhanden, die englische Version gibt es hier: <a href="commandref.html#Shelly">Shelly</a>
</ul>
=end html_DE
=cut
