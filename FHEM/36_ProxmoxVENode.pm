################################################################
#
#  $Id: 36_ProxmoxVENode.pm 8471 2020-11-04 17:46:01Z Carlos $
#
#  (c) 2019 Copyright: Carlos
#  forum : http://forum.fhem.de/index.php/topic,34131.0.html
#  All rights reserved
#
#  This code is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
################################################################
#  Changelog:

package main;
my $version="0.3.2 BETA";

use strict;
use warnings;
use SetExtensions;

sub ProxmoxVENode_Initialize($) {
  my ($hash) = @_;
  $hash->{DefFn}         = "ProxmoxVENode_Define";
  $hash->{UndefFn}       = "ProxmoxVENode_Undef";
  # $hash->{DeleteFn}      = "ProxmoxVENode_Delete";
  # $hash->{ParseFn}       = "ProxmoxVENode_Parse";
  # $hash->{AttrFn}        = "ProxmoxVENode_Attr";
  $hash->{SetFn}         = "ProxmoxVENode_Set";
  $hash->{GetFn}         = "ProxmoxVENode_Get";
  $hash->{AttrList}      = "disable:1,0 " .
					       "interval "
						   .$readingFnAttributes;
  $hash->{Match}     = "^ProxmoxVENode";
}

###################################

sub ProxmoxVENode_Define($$) {

  my ( $hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my $name = $a[0];
  my $sub_name = (caller(0))[3];

  return "Wrong syntax: use define <name> ProxmoxVENode <id> <clientName>" if(int(@a) < 2);

  my $id = $a[2];
  my $address = $a[3];

  if(defined($modules{ProxmoxVENode}{defptr}{$address})){
      return "Client with name $address already defined in ".($modules{ProxmoxVENode}{defptr}{$address}{NAME});
  }

  $hash->{CODE}      = $address;
  $hash->{ID}        = $id;
  $hash->{PVETYPE}   = (split(/\//, $id))[0];
  $hash->{SUBTYPE}   = (split(/\//, $id))[0];
  $hash->{VERSION}   = $version;
  $hash->{NOTIFYDEV} = "global";
  $hash->{INTERVAL}  = 300;

    # $attr{$name}{alias}         = "Service $service";
    $attr{$name}{cmdIcon}       = "reboot:rc_REPEAT stop:rc_STOP status:rc_INFO start:rc_PLAY";
    $attr{$name}{devStateIcon}  = "Initialized|status:light_question error|failed:light_exclamation running:audio_play:stop stopped:audio_stop:start stopping:audio_stop .*starting:audio_repeat";
    # $attr{$name}{room}          = "Services";
    # $attr{$name}{icon}          = "hue_room_garage";
    $attr{$name}{webCmd}        = "start:reboot:stop:status:shutdown";

  # Adresse r�ckw�rts dem Hash zuordnen (f�r ParseFn)
  $modules{ProxmoxVENode}{defptr}{$address} = $hash;

  AssignIoPort($hash);

  $hash->{STATE}   = "defined" ;

  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "ProxmoxVENode_statusRequest", $hash, 0);

  return undef;
}

###################################

sub ProxmoxVENode_statusRequest($) {

  my ( $hash) = @_;
  my $name = $hash->{NAME};
  my $id = $hash->{ID};

  my $sub_name = (caller(0))[3];

  InternalTimer(gettimeofday()+60, "ProxmoxVENode_statusRequest", $hash, 1);

  ProxmoxVENode_getNodeStatus($hash,$id);

  return 0;
}

sub Proxmox_getResourcebyId($$) {
  my ($hash, $id) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $PVE = $hash->{IODev}->{PVE};
  my $resources = $PVE->get('/cluster/resources');

  my $device;
  foreach my $item( @$resources ) {
    if (defined $item->{id} && ($item->{id} eq $id)) {
      $device = $item;
    } else {
      next;
    }
  }
  return $device;
}

sub Proxmox_getStatus($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $node =ReadingsVal( $name, "node", 0 );
  my $vmid =ReadingsVal( $name, "vmid", 0 );
  my $type =ReadingsVal( $name, "type", 0 );
  my $api = "/nodes/$node/$type/$vmid/status/current";

  my $PVE = $hash->{IODev}->{PVE};
  my $status = $PVE->get($api);

  return $status->{status};
}

sub ProxmoxVENode_getNodeStatus($$) {
  my ($hash,$id) = @_;
  my $name = $hash->{NAME};
  my $sub_name = (caller(0))[3];

  my $node =Proxmox_getResourcebyId($hash,$id) ;
  Log3 $name, 4,"[$sub_name] Node: " . Dumper(encode_json($node));

  readingsBeginUpdate($hash);
  readingsSingleUpdate($hash, "cpu", $node->{cpu}, "N/A");
  readingsSingleUpdate($hash, "disk", $node->{disk}, "N/A");
  readingsSingleUpdate($hash, "id", $node->{id}, "N/A");
  readingsSingleUpdate($hash, "maxcpu", $node->{maxcpu}, "N/A");
  readingsSingleUpdate($hash, "maxdisk", $node->{maxdisk}, "N/A");
  readingsSingleUpdate($hash, "maxmem", $node->{maxmem}, "N/A");
  readingsSingleUpdate($hash, "mem", $node->{mem}, "N/A");
  readingsSingleUpdate($hash, "node", $node->{node}, "N/A");
  readingsSingleUpdate($hash, "status", $node->{status}, "N/A");
  readingsSingleUpdate($hash, "type", $node->{type}, "N/A");
  readingsSingleUpdate($hash, "uptime", secs2human($node->{uptime}), "N/A");
  readingsSingleUpdate($hash, "json", encode_json($node), "N/A");

  readingsSingleUpdate($hash,"state",$node->{status},1);
  readingsEndUpdate($hash,1);

  $hash->{STATE} = $node->{status};
}

sub ProxmoxVENode_Undef($$) {
 	my ($hash, $name) = @_;
    my $sub_name = (caller(0))[3];

	RemoveInternalTimer($hash);

	if(defined($hash->{CODE}) && defined($modules{ProxmoxVENode}{defptr}{$hash->{CODE}})){
		delete($modules{ProxmoxVENode}{defptr}{$hash->{CODE}});
	}

	return undef;
}

########################################################################################
#
# ProxmoxVENode_Set - Implements SetFn function
#
# Parameter hash, a = argument array
#
########################################################################################

sub ProxmoxVENode_Set ($$@) {
  my ( $hash, $name, $cmd, @arg ) = @_;
  my $sub_name = (caller(0))[3];

  my $PVE = $hash->{IODev}->{PVE};

  my $model   = $hash->{MODEL};

  my ($success,$setlist);

  return if(IsDisabled($name));

  if( $hash->{SUBTYPE} eq "lxc" || $hash->{SUBTYPE} eq "qemu") {
    my $list="";
    $list = " start:noArg stop:noArg reboot:noArg shutdown:noArg resume:noArg suspend:noArg ";
    my $node =ReadingsVal( $name, "node", 0 );
    my $vmid =ReadingsVal( $name, "vmid", 0 );
    my $type =ReadingsVal( $name, "type", 0 );
    my $api = "/nodes/$node/$type/$vmid/status/$cmd";

    if ( $cmd eq 'start' ) {
     my $status = PVE_getStatus($hash);
     if ( $status eq 'running' ) {
       return "$vmid already running";
     } else {
       my $ret = $PVE->post($api);
      return undef;
     }
    } elsif ( lc $cmd eq "stop" ) {
     my $status = PVE_getStatus($hash);
     if ( $status eq 'stopped' ) {
       return "$vmid already stopped";
     } else {
       my $ret = $PVE->post($api);
       return undef;
     }
    } elsif ( lc $cmd eq "reboot" ) {
     my $status = Proxmox_getStatus($hash);
     if ( $status eq 'stopped' ) {
       return "$vmid already stopped, no reboot possible";
     } else {
       my $ret = $PVE->post($api);
      return undef;
     }
      return undef;
    } elsif ( lc $cmd eq "shutdown" ) {
       my $ret = $PVE->post($api);
       return undef;
    } elsif ( lc $cmd eq "resume" ) {
       my $ret = $PVE->post($api);
       return undef;
    } elsif ( lc $cmd eq "suspend" ) {
       my $ret = $PVE->post($api);
       return undef;
    }
    return "Unknown argument $cmd, choose one of $list";
  }
}


########################################################################################
#
# ProxmoxVENode_Get -  Implements GetFn function
#
# Parameter hash, argument array
#
########################################################################################

sub ProxmoxVENode_Get ($@) {

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

  $getlist = "Unknown argument $opt, choose one of ".
                   "statusRequest:noArg ".
         		   "storedCredentials:noArg "
                   ;

  return if(IsDisabled($name));

  if ($opt eq "statusRequest") {
    ProxmoxVENode_statusRequest($hash);
    return undef;
  } elsif ($opt eq "All") {
  	ProxmoxVE_getAll($hash);
    return undef;
  } elsif ($opt eq "DefineNodes") {
  	ProxmoxVE_DefineNodes($hash);
  	return undef;
  } else {
    return "$getlist";
  }

  return $ret;                                                        # not generate trigger out of command
}

1;

=pod
=begin html

<a name="ProxmoxVENode"></a>
<h3>ProxmoxVENode</h3>
<ul>
  <table><tr><td>
  sub device for the ProxmoxVE modul
  </td></tr></table>

  <a name="ProxmoxNodedefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ProxmoxVENode &lt;ID&gt;  &lt;device #&gt;</code>
  </ul>

  <a name="ProxmoxVENodeset"></a>
  <b>Set </b>
  <ul><a href="#setExtensions">set Extensions</a>
  </ul>
</ul>
=end html
