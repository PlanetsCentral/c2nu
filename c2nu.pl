#!/usr/bin/perl -w
#
#  vgaplanets.nu interface
#
#  This script accesses the Nu server by HTTP and converts between Nu
#  data and VGA Planets data. It operates in the current directory. It
#  will maintain a state file which stores some settings as well as
#  required cookies.
#
#  A Nu RST file is a JSON data structure and contains the
#  specification files, RST, and some history data.
#
#  Usage:
#    perl c2nu.pl [--host=H] [--backups=[01]] [--root=DIR] CMD [ARGS...]
#
#  Options:
#    --host=H       set host name (setting will be stored in state file)
#    --backups=0/1  disable/enable backup of received Nu RST files. Note
#                   that those are rather big so it makes sense to compress
#                   the backups.
#    --root=DIR     set root directory containing VGA Planets spec files.
#                   Those are used to "fill in the blanks" not contained
#                   in a Nu RST.
#
#  Commands:
#    help           Help screen (no network access)
#    status         Show state file content (no network access)
#    login U PW     Log in with user Id and password
#    list           List games (must be logged in)
#    rst [GAME]     Download Nu RST (must be logged in). GAME is the game
#                   number and can be omitted on second and later uses.
#                   Convert the Nu RST file to VGAP RST.
#    dump [GAME]    Download Nu RST and dump beautified JSON.
#    vcr [GAME]     Download Nu RST and create VGAP VCRx.DAT for PlayVCR.
#
#  All download commands can be split in two halves, i.e. "vcr1 [GAME]"
#  to perform the download, and "vcr2" to convert the download without
#  accessing the network.
#
#  Instructions:
#  - make a directory and go there using the command prompt
#  - log in using 'c2nu --host=planets.nu login USER PASS'
#  - list games using 'c2nu list'
#  - download a game using 'c2nu --root=DIR rst', where DIR is the
#    directory containing your VGA Planets installation, or PCC2's
#    'specs' direcory. Alternatively, copy a 'hullfunc.dat' file
#    into the current directory before downloading the game.
#
#  Since the server usually sends gzipped data, this script needs the
#  'gzip' program in the path to decompress it.
#
#  (c) 2011 Stefan Reuther
#
use strict;
use Socket;
use IO::Handle;
use bytes;              # without this, perl 5.6.1 doesn't correctly read Unicode stuff

#my $opt_jsonDebug = 1;
my $opt_rootDir = "/usr/share/planets";

# Initialisation
stateSet('host', 'planets.nu');
stateLoad();

# Parse arguments
while (@ARGV) {
    if ($ARGV[0] =~ /^--?host=(.*)/) {
        stateSet('host', $1);
        shift @ARGV;
    } elsif ($ARGV[0] =~ /^--?backup=(\d+)/) {
        stateSet('backups', $1);
        shift @ARGV;
    } elsif ($ARGV[0] =~ /^--?root=(.*)/) {
        $opt_rootDir = $1;
        shift @ARGV;
    } else {
        last;
    }
}

# Command switch
if (!@ARGV) {
    die "Missing command name.\n";
}
my $cmd = shift @ARGV;
$cmd =~ s/^--?//;
if ($cmd eq 'help') {
    doHelp();
} elsif ($cmd eq 'status') {
    doStatus();
} elsif ($cmd eq 'login') {
    doLogin();
} elsif ($cmd eq 'list') {
    doList();
} elsif ($cmd =~ /^rst([12]?)$/) {
    doDownloadResult() unless $1 eq '2';
    doWriteResult()    unless $1 eq '1';
} elsif ($cmd =~ /^dump([12]?)$/) {
    doDownloadResult() unless $1 eq '2';
    doDump()           unless $1 eq '1';
} elsif ($cmd =~ /^vcr([12]?)$/) {
    doDownloadResult() unless $1 eq '2';
    doWriteVcr()       unless $1 eq '1';
} else {
    die "Invalid command '$cmd'\n";
}
stateSave();
exit 0;

######################################################################
#
#  Help
#
######################################################################
sub doHelp {
    print <<EOF;
$0 - vgaplanets.nu interface

$0 [options] command [command args]

Options:
  --host=HOST       instead of 'vgaplanets.nu'
  --backups=0/1     disable/enable backup of Nu RST
  --root=DIR        set root directory containing VGA Planets spec files

Commands:
  help              this help screen
  status            show status
  login USER PASS   log in
  list              list games
  rst [GAME]        download Nu RST and convert to VGAP RST
  dump [GAME]       download Nu RST and dump JSON
  vcr [GAME]        download Nu RST and create VGAP VCRx.DAT

Download commands can be split into the download part ('vcr1') and the
convert part ('vcr2').
EOF
}

######################################################################
#
#  Log in
#
######################################################################
sub doLogin {
    if (@ARGV != 2) {
        die "login: need two arguments, user name and password\n";
    }

    my $user = $ARGV[0];
    my $pass = $ARGV[1];

    my $reply = httpCall("POST /_ui/signin?method=Authenticate&type=get HTTP/1.0\n",
                         httpBuildQuery(UserName => $user,
                                        Password => $pass,
                                        Remember => 'true'));

    my $parsedReply = jsonParse($reply->{BODY});
    if (exists($parsedReply->{success}) && $parsedReply->{success} =~ /true/i) {
        print "++ Login succeeded ++\n";
        stateSet('user', $user);
        foreach (sort keys %$reply) {
            if (/^COOKIE-(.*)/) {
                stateSet("cookie_$1", $reply->{$_});
            }
        }
    } else {
        print "++ Login failed ++\n";
        print "Server answer:\n";
        foreach (sort keys %$parsedReply) {
            printf "%-20s %s\n", $_, $parsedReply->{$_};
        }
    }
}

######################################################################
#
#  List
#
######################################################################
sub doList {
    my $reply = httpCall("POST /_ui/plugins?method=Refresh&type=get&assembly=PlanetsNu.dll&object=PlanetsNu.DashboardFunctions HTTP/1.0\n", "");
    my $parsedReply = jsonParse($reply->{BODY});
    my $needHeader = 1;
    if (exists($parsedReply->{games})) {
        my $parsedXML = xmlParse($parsedReply->{games});
        foreach my $table (xmlIndirectChildren('table', $parsedXML)) {
            my @rows = xmlIndirectChildren('tr', @{$table->{CONTENT}});

            # Find game type
            my $type = "Games";
            if (@rows
                && $rows[0]{CONTENT}[0]{TAG} eq 'th'
                && !ref($rows[0]{CONTENT}[0]{CONTENT}[0]))
            {
                $type = $rows[0]{CONTENT}[0]{CONTENT}[0];
                shift @rows;
            }

            # Find game number: there is a link with "planetsDashboard.loadGame(<nr>);return false"
            my $gameNr = 0;
            foreach my $a (xmlIndirectChildren('a', xmlMergeContent(@rows))) {
                if (exists($a->{onclick}) && $a->{onclick} =~ m#planetsDashboard.loadGame\((\d+)\)#) {
                    $gameNr = $1;
                }
            }
            next if !$gameNr;

            # Find race: there is an image at "http://library.vgaplanets.nu/races/<race>.png"
            my $race = 0;
            foreach my $img (xmlIndirectChildren('img', xmlMergeContent(@rows))) {
                if (exists($img->{src}) && $img->{src} =~ m#/races/(\d+)\.(png|jpg|gif)#i) {
                    $race = $1;
                }
            }

            # Find game name: for real games, there is a link to "/games/<nr>".
            # For training games, there's a <div> starting with the number
            my $gameName = "";
            foreach my $a (xmlIndirectChildren('a', xmlMergeContent(@rows))) {
                if (exists($a->{href}) && $a->{href} =~ m#/games/(\d+)#) {
                    print "WARNING: game '$gameNr' links to '$1'\n" if $1 ne $gameNr;
                    $gameName = xmlTextContent(@{$a->{CONTENT}});
                }
            }
            if ($gameName eq '') {
                foreach my $div (xmlIndirectChildren('div', xmlMergeContent(@rows))) {
                    my $text = xmlTextContent(@{$div->{CONTENT}});
                    if ($text =~ /^$gameNr:/) {
                        $gameName = $text;
                    }
                }
            }
            $gameName =~ s/^$gameNr:\s+//;

            # Print
            print "Game      Name                                      Race  Category\n" if $needHeader;
            print "--------  ----------------------------------------  ----  --------------------\n" if $needHeader;
            printf "%8d  %-40s  %4d  %s\n", $gameNr, $gameName, $race, $type;
            $needHeader = 0;
        }
    } else {
        print "++ Unable to obtain game list ++\n";
    }
}


######################################################################
#
#  VCR file
#
######################################################################

sub doWriteVcr {
    # Read state
    open IN, "< c2rst.txt" or die "c2rst.txt: $!\n";
    my $body;
    while (1) {
        my $tmp;
        if (!read(IN, $tmp, 4096)) { last }
        $body .= $tmp;
    }
    close IN;

    print "Parsing result...\n";
    doVcr(jsonParse($body));
}

sub doVcr {
    # Fetch parameter
    my $parsedReply = shift;
    if (!exists $parsedReply->{rst}) {
        die "ERROR: no result file received\n";
    }
    if (!$parsedReply->{rst}{player}{raceid}) {
        die "ERROR: result does not contain player name\n";
    }
    if ($parsedReply->{rst}{player}{savekey} ne $parsedReply->{savekey}) {
        die "ERROR: received two different savekeys\n"
    }
    stateSet('savekey', $parsedReply->{savekey});
    stateSet('player', $parsedReply->{rst}{player}{raceid});

    # Make spec files
    makeSpecFile($parsedReply->{rst}{beams}, "beamspec.dat", 10, "A20v8", 36,
                 qw(name cost tritanium duranium molybdenum mass techlevel crewkill damage));
    makeSpecFile($parsedReply->{rst}{torpedos}, "torpspec.dat", 10, "A20v9", 38,
                 qw(name torpedocost launchercost tritanium duranium molybdenum mass techlevel crewkill damage));
    makeSpecFile($parsedReply->{rst}{engines}, "engspec.dat", 9, "A20v5V9", 66,
                 qw(name cost tritanium duranium molybdenum techlevel warp1 warp2 warp3 warp4 warp5 warp6 warp7 warp8 warp9));
    makeSpecFile($parsedReply->{rst}{hulls}, "hullspec.dat", 105, "A30v15", 60,
                 qw(name zzimage zzunused tritanium duranium molybdenum fueltank
                    crew engines mass techlevel cargo fighterbays launchers beams cost));
    makeSpecFile($parsedReply->{rst}{planets}, "xyplan.dat", 500, "v3", 6,
                 qw(x y ownerid));
    makeSpecFile($parsedReply->{rst}{planets}, "planet.nm", 500, "A20", 20,
                 qw(name));

    # Make more spec files
    makeHullfuncFile($parsedReply->{rst}{hulls});
    makeTruehullFile($parsedReply->{rst}{racehulls}, $parsedReply->{rst}{player}{raceid});

    # Make result
    my $player = $parsedReply->{rst}{player}{id};
    my $vcrs = rstPackVcrs($parsedReply, $player);
    my $fn = "vcr$player.dat";
    open VCR, "> $fn" or die "$fn: $!\n";
    print "Making $fn...\n";
    binmode VCR;
    print VCR $vcrs;
    close VCR;
}


######################################################################
#
#  Result file
#
######################################################################

sub doDownloadResult {
    my $gameId;
    if (@ARGV == 0) {
        $gameId = stateGet('gameid');
        if (!$gameId) {
            die "rst1: need one parameter: game name\n";
        }
    } elsif (@ARGV == 1) {
        $gameId = shift @ARGV;
    } else {
        die "rst1: need one parameter: game name\n";
    }
    stateSet('gameid', $gameId);

    my $reply = httpCall("POST /_ui/plugins?method=LoadGameData&type=get&assembly=PlanetsNu.dll&object=PlanetsNu.GameFunctions HTTP/1.0\n",
                         httpBuildQuery(gameId => $gameId));

    print "Saving output...\n";
    open OUT, "> c2rst.txt" or die "c2rst.txt: $!\n";
    print OUT $reply->{BODY};
    close OUT;

    print "Parsing result...\n";
    my $parsedReply = jsonParse($reply->{BODY});
    if (!exists $parsedReply->{rst}) {
        print STDERR "WARNING: request probably did not succeed.\n";
        if (exists $parsedReply->{error}) {
            print STDERR "WARNING: error message is:\n\t", $parsedReply->{error}, "\n";
        }
    } else {
        if (stateGet('backups')) {
            print "Making backup...\n";
            my $turn = $parsedReply->{rst}{settings}{turn};
            my $player = $parsedReply->{rst}{player}{raceid};
            open OUT, sprintf("> c2rst_backup_%d_%03d.txt", $player, $turn);
            print OUT $reply->{BODY};
            close OUT;
        }
    }
}

sub doWriteResult {
    # Read state
    open IN, "< c2rst.txt" or die "c2rst.txt: $!\n";
    my $body;
    while (1) {
        my $tmp;
        if (!read(IN, $tmp, 4096)) { last }
        $body .= $tmp;
    }
    close IN;

    print "Parsing result...\n";
    doResult(jsonParse($body));
}

sub doResult {
    # Fetch parameter
    my $parsedReply = shift;
    if (!exists $parsedReply->{rst}) {
        die "ERROR: no result file received\n";
    }
    if (!$parsedReply->{rst}{player}{raceid}) {
        die "ERROR: result does not contain player name\n";
    }
    if ($parsedReply->{rst}{player}{savekey} ne $parsedReply->{savekey}) {
        die "ERROR: received two different savekeys\n"
    }
    stateSet('savekey', $parsedReply->{savekey});
    stateSet('player', $parsedReply->{rst}{player}{raceid});

    # Find timestamp. It has the format
    #  8/12/2011 9:00:13 PM
    #  8/7/2011 1:33:42 PM
    my @time = split m|[/: ]+|, $parsedReply->{rst}{settings}{hoststart};
    if (@time != 7) {
        print "WARNING: unable to figure out a reliable timestamp\n";
        while (@time < 7) {
            push @time, 0;
        }
    } else {
        # Convert to international time format
        if ($time[3] == 12) { $time[3] = 0 }
        if ($time[4] eq 'PM') { $time[3] += 12 }
    }
    my $timestamp = substr(sprintf("%02d-%02d-%04d%02d:%02d:%02d", @time), 0, 18);

    # Make spec files
    makeSpecFile($parsedReply->{rst}{beams}, "beamspec.dat", 10, "A20v8", 36,
                 qw(name cost tritanium duranium molybdenum mass techlevel crewkill damage));
    makeSpecFile($parsedReply->{rst}{torpedos}, "torpspec.dat", 10, "A20v9", 38,
                 qw(name torpedocost launchercost tritanium duranium molybdenum mass techlevel crewkill damage));
    makeSpecFile($parsedReply->{rst}{engines}, "engspec.dat", 9, "A20v5V9", 66,
                 qw(name cost tritanium duranium molybdenum techlevel warp1 warp2 warp3 warp4 warp5 warp6 warp7 warp8 warp9));
    makeSpecFile($parsedReply->{rst}{hulls}, "hullspec.dat", 105, "A30v15", 60,
                 qw(name zzimage zzunused tritanium duranium molybdenum fueltank
                    crew engines mass techlevel cargo fighterbays launchers beams cost));
    makeSpecFile($parsedReply->{rst}{planets}, "xyplan.dat", 500, "v3", 6,
                 qw(x y ownerid));
    makeSpecFile($parsedReply->{rst}{planets}, "planet.nm", 500, "A20", 20,
                 qw(name));

    # Make more spec files
    makeHullfuncFile($parsedReply->{rst}{hulls});
    makeTruehullFile($parsedReply->{rst}{racehulls}, $parsedReply->{rst}{player}{raceid});

    # Make result
    makeResult($parsedReply, $parsedReply->{rst}{player}{id}, $timestamp);

    # Make util.dat with assorted info
    makeUtilData($parsedReply, $parsedReply->{rst}{player}{id}, $timestamp);
}

# Make specification file from data received within nu RST
sub makeSpecFile {
    my $replyPart = shift;
    my $fileName = shift;
    my $numEntries = shift;
    my $packPattern = shift;
    my $entrySize = shift;
    my @fields = @_;

    print "Making $fileName...\n";

    # Build field-to-slot mapping and entry template
    my %fieldToSlot;
    my @entryTemplate;
    foreach (0 .. $#fields) {
        $fieldToSlot{$fields[$_]} = $_;
        push @entryTemplate, 0;
    }

    # Load existing file or build empty file
    my @file;
    if (open(FILE, "< $fileName") || open(FILE, "< $opt_rootDir/$fileName")) {
        binmode FILE;
        foreach (1 .. $numEntries) {
            my $buf;
            read FILE, $buf, $entrySize;
            push @file, [unpack $packPattern, $buf];
        }
        close FILE;
    } else {
        if ($fileName eq 'hullspec.dat') {
            print "WARNING: 'hullspec.dat' created from scratch; it will not contain image references.\n";
            print "    Copy a pre-existing 'hullspec.dat' into this directory and process the RST again\n";
            print "    to have images.\n";
        }
        foreach (1 .. $numEntries) {
            if (exists $fieldToSlot{name}) { $entryTemplate[$fieldToSlot{name}] = "#$_"; }
            push @file, [@entryTemplate];
        }
    }

    # Populate file
    foreach my $e (@$replyPart) {
        if ($e->{id} > 0 && $e->{id} <= $numEntries) {
            foreach (sort keys %$e) {
                if (exists $fieldToSlot{$_}) {
                    $file[$e->{id} - 1][$fieldToSlot{$_}] = $e->{$_};
                }
            }
        }
    }

    # Generate it
    open FILE, "> $fileName" or die "$fileName: $!\n";
    binmode FILE;
    foreach (@file) {
        print FILE pack($packPattern, @$_);
    }
    close FILE;
}

sub makeHullfuncFile {
    # Nu stores cloakiness in its spec file, but all other hull
    # functions appear as free-form text only. We therefore assume
    # the hull functions to be reasonably default, and generate
    # a hullfunc file which only updates the Cloak ability.
    # FIXME: what about AdvancedCloak?
    my $hulls = shift;
    print "Making hullfunc.txt...\n";
    open FILE, "> hullfunc.txt" or die "hullfunc.txt: $!\n";
    print FILE "# Hull function definitions for 'nu' game\n\n";
    print FILE "\%hullfunc\n\n";
    print FILE "Init = Default\n";
    print FILE "Function = Cloak\n";
    print FILE "Hull = *\n";
    print FILE "RacesAllowed = -\n";
    foreach (@$hulls) {
        if ($_->{cancloak}) {
            print FILE "Hull = ", $_->{id}, "\n";
            print FILE "RacesAllowed = +\n";
        }
    }
    close FILE;
}

sub makeTruehullFile {
    my $pRacehulls = shift;
    my $player = shift;

    print "Making truehull.dat...\n";

    # Load existing file if any
    my @truehull = replicate(20*11, 0);
    if (open(TH, "< truehull.dat") or open(TH, "< $opt_rootDir/truehull.dat")) {
        my $th;
        binmode TH;
        read TH, $th, 20*11*2;
        close TH;
        @truehull = unpack("v*", $th);
    }

    # Merge race hulls
    for (my $i = 0; $i < 20; ++$i) {
        $truehull[($player-1)*20 + $i] = ($i < @$pRacehulls ? $pRacehulls->[$i] : 0);
    }

    # Write
    open(TH, "> truehull.dat") or die "truehull.dat: $!\n";
    binmode TH;
    print TH pack("v*", @truehull);
    close TH;
}

sub makeResult {
    my $parsedReply = shift;
    my $player = shift;
    my $timestamp = shift;
    my $race = rstMapOwnerToRace($parsedReply, $player);
    my $fileName = "player$race.rst";
    print "Making $fileName...\n";

    # Create result file with stub header
    # Sections are:
    #   ships
    #   targets
    #   planets
    #   bases
    #   messages
    #   shipxy
    #   gen
    #   vcr
    #   kore
    #   skore
    my @offsets = replicate(10, 0);
    open RST, "> $fileName" or die "$fileName: $!\n";
    binmode RST;
    rstWriteHeader(@offsets);

    # Make file sections
    my $ships = rstPackShips($parsedReply, $player);
    $offsets[0] = tell(RST)+1;
    print RST $ships;

    my $targets = rstPackTargets($parsedReply, $player);
    $offsets[1] = tell(RST)+1;
    print RST $targets;

    my $planets = rstPackPlanets($parsedReply, $player);
    $offsets[2] = tell(RST)+1;
    print RST $planets;

    my $bases = rstPackBases($parsedReply, $player);
    $offsets[3] = tell(RST)+1;
    print RST $bases;

    my @msgs = (rstPackMessages($parsedReply, $player),
                rstSynthesizeMessages($parsedReply, $player));
    $offsets[4] = tell(RST)+1;
    rstWriteMessages(@msgs);

    my $shipxy = rstPackShipXY($parsedReply, $player);
    $offsets[5] = tell(RST)+1;
    print RST $shipxy;

    my $gen = rstPackGen($parsedReply, $player, $ships, $planets, $bases, $timestamp);
    $offsets[6] = tell(RST)+1;
    print RST $gen;

    my $vcrs = rstPackVcrs($parsedReply, $player);
    $offsets[7] = tell(RST)+1;
    print RST $vcrs;

    # Finish
    rstWriteHeader(@offsets);
    close RST;

    my $trn = "player$race.trn";
    if (unlink($trn)) {
        print "Removed $trn.\n";
    }
}

sub makeUtilData {
    my $parsedReply = shift;
    my $player = shift;
    my $timestamp = shift;
    my $race = rstMapOwnerToRace($parsedReply, $player);
    my $fileName = "util$race.dat";
    print "Making $fileName...\n";

    open UTIL, "> $fileName" or die "$fileName: $!\n";
    binmode UTIL;
    utilWrite(13,
              $timestamp . pack("vvCCV8A32",
                                $parsedReply->{rst}{settings}{turn},
                                $race,
                                3, 0,       # claim to be Host 3.0
                                0, 0, 0, 0, 0, 0, 0, 0,  # digests not filled in
                                $parsedReply->{rst}{settings}{name}));

    # Scores
    utilMakeScore($parsedReply, "militaryscore",  1000, "Military Score (Nu)");
    utilMakeScore($parsedReply, "inventoryscore", 1001, "Inventory Score (Nu)");
    utilMakeScore($parsedReply, "prioritypoints",    2, "Build Points (Nu)");

    # Ion storms (FIXME: should place them in RST)
    foreach (@{$parsedReply->{rst}{ionstorms}}) {
        utilWrite(17, pack("v9",
                           $_->{id},
                           $_->{x},
                           $_->{y},
                           $_->{voltage},
                           $_->{heading},
                           $_->{warp},
                           $_->{radius},
                           int(($_->{voltage} + 49)/50),
                           $_->{isgrowing}));
    }

    # Minefields
    foreach (@{$parsedReply->{rst}{minefields}}) {
        # Only current fields. Old fields are managed by PCC.
        if ($_->{infoturn} == $parsedReply->{rst}{settings}{turn}) {
            # ignored fields: friendlycode, radius
            utilWrite(0, pack("vvvvVv",
                              $_->{id},
                              $_->{x},
                              $_->{y},
                              rstMapOwnerToRace($parsedReply, $_->{ownerid}),
                              $_->{units},
                              $_->{isweb} ? 1 : 0));
        }
    }

    # Allied bases
    foreach my $base (@{$parsedReply->{rst}{starbases}}) {
        # Since we're getting allied bases as well, we must filter here
        my $baseOwner = rstGetBaseOwner($base, $parsedReply);
        if ($baseOwner != 0 && $baseOwner != $player) {
            utilWrite(11, pack("vv", $base->{planetid}, rstMapOwnerToRace($parsedReply, $baseOwner)));
        }
    }

    # TODO: explosions. Problem is that PCC2 cannot yet display those.
    # TODO: enemy planet scans

    close UTIL;
}


######################################################################
#
#  Dumping
#
######################################################################

sub doDump {
    # Read state
    open IN, "< c2rst.txt" or die "c2rst.txt: $!\n";
    my $body;
    while (1) {
        my $tmp;
        if (!read(IN, $tmp, 4096)) { last }
        $body .= $tmp;
    }
    close IN;
    jsonDump(jsonParse($body), "");
}

######################################################################
#
#  UTIL.DAT creation
#
######################################################################

sub utilWrite {
    my $type = shift;
    my $data = shift;
    print UTIL pack("vv", $type, length($data)), $data;
}

sub utilMakeScore {
    my ($parsedReply, $key, $utilId, $utilName) = @_;
    my @scores = replicate(11, -1);
    foreach (@{$parsedReply->{rst}{scores}}) {
        $scores[rstMapOwnerToRace($parsedReply, $_->{ownerid})-1] = $_->{$key};
    }
    utilWrite(51, pack("A50vvVV11", $utilName, $utilId, -1, -1, @scores));
}

######################################################################
#
#  RST creation
#
######################################################################

sub rstWriteHeader {
    my @offsets = @_;
    seek RST, 0, 0;
    print RST pack("V8", @offsets[0 .. 7]), "VER3.501", pack("V3", $offsets[8], 0, $offsets[9]);
}

# Create ship section. Returns whole section as a string.
sub rstPackShips {
    my $parsedReply = shift;
    my $player = shift;
    my @packedShips;
    foreach my $ship (@{$parsedReply->{rst}{ships}}) {
        if ($ship->{ownerid} == $player) {
            my $p = rstPackFields($ship, "v", qw(id));
            $p .= pack("v", rstMapOwnerToRace($parsedReply, $ship->{ownerid}));
            $p .= rstPackFields($ship,
                                "A3v",
                                qw(friendlycode warp));
            $p .= pack("vv",
                       $ship->{targetx} - $ship->{x},
                       $ship->{targety} - $ship->{y});
            $p .= rstPackFields($ship,
                                "v10",
                                qw(x y engineid hullid beamid beams bays torpedoid ammo torps));
            if ($ship->{mission} >= 0) {
                # Missions are off-by-one!
                $p .= pack("v", $ship->{mission} + 1);
            } else {
                $p .= pack("v", $ship->{mission});
            }
            $p .= pack("v", rstMapOwnerToRace($parsedReply, $ship->{enemy}));
            $p .= pack("v", $ship->{mission} == 6 ? $ship->{mission1target} : 0);
            $p .= rstPackFields($ship,
                                "v3A20v5",
                                qw(damage crew clans name
                                   neutronium tritanium duranium molybdenum supplies));

            # FIXME: jettison?
            if ($ship->{transfertargettype} == 1) {
                # Unload
                $p .= rstPackFields($ship,
                                    "v7",
                                    qw(transferneutronium transfertritanium
                                       transferduranium transfermolybdenum
                                       transferclans transfersupplies
                                       transfertargetid));
            } else {
                $p .= "\0" x 14;
            }
            if ($ship->{transfertargettype} == 2) {
                # Transfer
                $p .= rstPackFields($ship,
                                    "v7",
                                    qw(transferneutronium transfertritanium
                                       transferduranium transfermolybdenum
                                       transferclans transfersupplies
                                       transfertargetid));
            } else {
                $p .= "\0" x 14;
            }
            if ($ship->{transfermegacredits} || $ship->{transferammo}) {
                print "WARNING: transfer of mc and/or ammo not implemented yet\n";
            }
            $p .= pack("v", $ship->{mission} == 7 ? $ship->{mission1target} : 0);
            $p .= rstPackFields($ship,
                                "v",
                                qw(megacredits));
            push @packedShips, $p;
        }
    }

    pack("v", scalar(@packedShips)) . join('', @packedShips);
}

# Create target section.
sub rstPackTargets {
    my $parsedReply = shift;
    my $player = shift;
    my @packedShips;
    foreach my $ship (@{$parsedReply->{rst}{ships}}) {
        if ($ship->{ownerid} != $player) {
            push @packedShips,
              rstPackFields($ship, "v", qw(id))
                . pack("v", rstMapOwnerToRace($parsedReply, $ship->{ownerid}))
                  . rstPackFields($ship,
                                  "v5A20",
                                  qw(warp x y hullid heading name));
        }
    }
    pack("v", scalar(@packedShips)) . join('', @packedShips);
}

# Create planet section.
sub rstPackPlanets {
    my $parsedReply = shift;
    my $player = shift;
    my @packedPlanets;

    # This field list is dually-used for packing and filtering.
    # A planet is included in the result if it has at least one
    # of those fields with a sensible value.
    my @fields = qw(mines factories defense
                    neutronium tritanium duranium molybdenum
                    clans supplies megacredits
                    groundneutronium groundtritanium groundduranium groundmolybdenum
                    densityneutronium densitytritanium densityduranium densitymolybdenum
                    colonisttaxrate nativetaxrate
                    colonisthappypoints nativehappypoints
                    nativegovernment
                    nativeclans
                    nativetype);
    foreach my $planet (@{$parsedReply->{rst}{planets}}) {
        if ($planet->{friendlycode} ne '???'
            || grep {$planet->{$_} > 0} @fields) {
            # FIXME: mines/factories/defense are after building,
            # supplies are after supply sale,
            # so doing it this way disallows undo in a partial turn!
            my $p = pack("v", rstMapOwnerToRace($parsedReply, $planet->{ownerid}));
            $p .= rstPackFields($planet,
                                "vA3v3V11v9Vv",
                                qw(id friendlycode), @fields);
            $p .= pack("v", $planet->{temp} >= 0 ? 100 - $planet->{temp} : -1);
            $p .= pack("v", $planet->{buildingstarbase});
            push @packedPlanets, $p;
        }
    }
    pack("v", scalar(@packedPlanets)) . join('', @packedPlanets);
}

sub rstPackBases {
    my $parsedReply = shift;
    my $player = shift;
    my @packedBases;
    my @myHulls = @{$parsedReply->{rst}{racehulls}};
    while (@myHulls < 20) { push @myHulls, 0 }
    foreach my $base (@{$parsedReply->{rst}{starbases}}) {
        # Since we're getting allied bases as well, we must filter here
        next if rstGetBaseOwner($base, $parsedReply) != $player;

        my $b = pack("v2", $base->{planetid}, rstMapOwnerToRace($parsedReply, $player));
        $b .= rstPackFields($base,
                            "v6",
                            qw(defense damage enginetechlevel
                               hulltechlevel beamtechlevel torptechlevel));
        $b .= rstPackStock($base->{id}, $parsedReply, 2, sequence(1, 9));
        $b .= rstPackStock($base->{id}, $parsedReply, 1, @myHulls);
        $b .= rstPackStock($base->{id}, $parsedReply, 3, sequence(1, 10));
        $b .= rstPackStock($base->{id}, $parsedReply, 4, sequence(1, 10));
        $b .= rstPackStock($base->{id}, $parsedReply, 5, sequence(1, 10));
        $b .= rstPackFields($base,
                            "v4",
                            qw(fighters targetshipid shipmission mission));
        my $buildSlot = 0;
        if ($base->{isbuilding}) {
            for (0 .. $#myHulls) {
                if ($base->{buildhullid} == $myHulls[$_]) {
                    $buildSlot = $_+1;
                    last;
                }
            }
            if (!$buildSlot) {
                print STDERR "WARNING: base $base->{planetid} is building a ship that you cannot build\n";
            }
        }
        $b .= pack("v", $buildSlot);
        $b .= rstPackFields($base,
                            "v5",
                            qw(buildengineid buildbeamid buildbeamcount buildtorpedoid buildtorpcount));
        $b .= pack("v", 0);
        push @packedBases, $b;
    }
    pack("v", scalar(@packedBases)) . join('', @packedBases);
}

sub rstPackMessages {
    my $parsedReply = shift;
    my $player = shift;
    my @result;

    # I have not yet seen all of these.
    my @templates = (
                     "(-r0000)<<< Outbound >>>",            # xx 0 'Outbound', should not appear in inbox
                     "(-h0000)<<< System >>>",              # 1 'System',
                     "(-s%04d)<<< Terraforming >>>",        # 2 'Terraforming',
                     "(-l%04d)<<< Minefield Laid >>>",      # 3 'Minelaying',
                     "(-m%04d)<<< Mine Sweep >>>",          # 4 'Minesweeping',
                     "(-p%04d)<<< Planetside Message >>>",  # 5 'Colony',
                     "(-f%04d)<<< Combat >>>",              # xx 6 'Combat',
                     "(-f%04d)<<< Fleet Message >>>",       # xx 7 'Fleet',
                     "(-s%04d)<<< Ship Message >>>",        # 8 'Ship',
                     "(-n%04d)<<< Intercepted Message >>>", # xx 9 'Enemy Distress Call',
                     "(-x0000)<<< Explosion >>>",           # 10 'Explosion',
                     "(-d%04d)<<< Space Dock Message >>>",  # 11 'Starbase',
                     "(-w%04d)<<< Web Mines >>>",           # 12 'Web Mines',
                     "(-y%04d)<<< Meteor >>>",              # xx 13 'Meteors',
                     "(-z%04d)<<< Sensor Sweep >>>",        # xx 14 'Sensor Sweep',
                     "(-z%04d)<<< Bio Scan >>>",            # xx 15 'Bio Scan',
                     "(-e%04d)<<< Distress Call >>>",       # xx 16 'Distress Call',
                     "(-r%04d)<<< Subspace Message >>>",    # xx 17 'Player',
                     "(-h0000)<<< Diplomacy >>>",           # xx 18 'Diplomacy',
                     "(-m%04d)<<< Mine Scan >>>",           # xx 19 'Mine Scan',
                     "(-9%04d)<<< Captain's Log >>>",       # xx  20 'Dark Sense',
                     "(-9%04d)<<< Sub Space Message >>>",   # xx 21 'Hiss'
                );

    # Build message list
    foreach my $m (sort {$b->{id} <=> $a->{id}} @{$parsedReply->{rst}{messages}}) {
        my $head = rstFormatMessage("From: $m->{headline}");
        my $body = rstFormatMessage($m->{body});
        my $template = ($m->{messagetype} >= 0 && $m->{messagetype} < @templates ? $templates[$m->{messagetype}] : "(-h0000)<<< Sub Space Message >>>");
        my $msg = sprintf($template, $m->{target}) . "\n\n" . $head . "\n\n" . $body;

        # Nu messages contain a coordinate. To let PCC know that, add it to
        # the message, unless it's already there.
        # Nu often uses '( 1234, 5678 )' for coordiantes. Strip the blanks to
        # make it look better.
        $body =~ s/\( +(\d+, *\d+) +\)/($1)/g;
        if ($m->{x} && $m->{y} && $msg !~ m|\($m->{x}, *$m->{y}\)|) {
            $msg .= "\n\nLocation: ($m->{x}, $m->{y})";
        }
        push @result, rstEncryptMessage($msg);
    }

    @result;
}

sub rstSynthesizeMessages {
    my $parsedReply = shift;
    my $player = shift;
    my @result;

    # Settings I (from 'game')
    my $text = rstSynthesizeMessage("(-h0000)<<< Game Settings (1) >>>",
                                    $parsedReply->{rst}{game},
                                    [name=>"Game Name: %s"], [description=>"Description: %s"], "\n", [hostdays=>"Host Days: %s"],
                                    [hosttime=>"Host Time: %s"], "\n", [masterplanetid=>"Master Planet Id: %s"]);
    push @result, rstEncryptMessage($text) if defined($text);

    # Settings II (from 'settings')
    $text = rstSynthesizeMessage("(-h0000)<<< Game Settings (2) >>>",
                                 $parsedReply->{rst}{settings},
                                 [buildqueueplanetid => "Build Queue Planet: %s"],
                                 [turn               => "Turn %s"],
                                 [victorycountdown   => "Victory Countdown: %s"],
                                 "\n",
                                 [hoststart          => "Host started: %s"],
                                 [hostcompleted      => "Host completed: %s"]);
    push @result, rstEncryptMessage($text) if defined($text);

    # Host config (from 'settings')
    $text = rstSynthesizeMessage("(-g0000)<<< Host Configuration >>>",
                                 $parsedReply->{rst}{settings},
                                 [cloakfail          => "Odds of cloak failure  %s %%"],
                                 [maxions            => "Ion Storms             %s"],
                                 [shipscanrange      => "Ships are visible at   %s"],
                                 [structuredecayrate => "structure decay        %s"],
                                 "\n",
                                 [mapwidth           => "Map width              %s"],
                                 [mapheight          => "Map height             %s"],
                                 [maxallies          => "Maximum allies         %s"],
                                 [numplanets         => "Number of planets      %s"],
                                 [planetscanrange    => "Planets are visible at %s"]);
    push @result, rstEncryptMessage($text) if defined($text);

    # HConfig arrays
    foreach ([freefighters=>"Free fighters at starbases", "%3s"],
             [groundattack=>"Ground Attack Kill Ratio", "%3s : 1"],
             [grounddefense=>"Ground Defense Kill Ratio", "%3s : 1"],
             [miningrate=>"Mining rates", "%3s"],
             [taxrate=>"Tax rates", "%3s"])
      {
          my $key = $_->[0];
          my $fmt = $_->[2];
          my $did = 0;
          $text = "(-g0000)<<< Host Configuration >>>\n\n$_->[1]\n";
          foreach my $r (@{$parsedReply->{rst}{races}}) {
              if (exists($r->{$key}) && exists($r->{adjective})) {
                  $text .= sprintf("  %-15s", $r->{adjective})
                    . sprintf($fmt, $r->{$key})
                      . "\n";
                  $did = 1;
              }
          }
          push @result, rstEncryptMessage($text) if $did;
      }

    @result;
}

sub rstSynthesizeMessage {
    my $head = shift;
    my $pHash = shift;
    my $text = "$head\n\n";
    my $did = 0;
    my $gap = 1;
    foreach (@_) {
        if (ref) {
            if (exists $pHash->{$_->[0]}) {
                $text .= sprintf($_->[1], $pHash->{$_->[0]}) . "\n";
                $did = 1;
                $gap = 0;
            }
        } else {
            $text .= $_ unless $gap;
            $gap = 1;
        }
    }
    return $did ? $text : undef;
}

sub rstPackShipXY {
    my $parsedReply = shift;
    my $player = shift;
    my @shipxy = replicate(999*4, 0);

    foreach my $ship (@{$parsedReply->{rst}{ships}}) {
        if ($ship->{id} > 0 && $ship->{id} <= 999) {
            my $pos = ($ship->{id} - 1) * 4;
            $shipxy[$pos]   = $ship->{x};
            $shipxy[$pos+1] = $ship->{y};
            $shipxy[$pos+2] = rstMapOwnerToRace($parsedReply, $ship->{ownerid});
            $shipxy[$pos+3] = $ship->{mass};
        }
    }

    pack("v*", @shipxy);
}

sub rstPackGen {
    my $parsedReply = shift;
    my $player = shift;
    my $ships = shift;
    my $planets = shift;
    my $bases = shift;
    my $timestamp = shift;

    # Find turn number
    my $turn = $parsedReply->{rst}{settings}{turn};

    # Find scores
    my @scores = replicate(44, 0);
    foreach my $p (@{$parsedReply->{rst}{scores}}) {
        if ($p->{ownerid} > 0 && $p->{ownerid} <= 11 && $p->{turn} == $turn) {
            my $pos = ((rstMapOwnerToRace($parsedReply, $p->{ownerid}) - 1) * 4);
            $scores[$pos] = $p->{planets};
            $scores[$pos+1] = $p->{capitalships};
            $scores[$pos+2] = $p->{freighters};
            $scores[$pos+3] = $p->{starbases};
        }
    }

    return $timestamp
      . pack("v*", @scores)
        . pack("v", rstMapOwnerToRace($parsedReply, $player))
          . "NOPASSWORD          "
            . pack("V*",
                   rstChecksum(substr($ships, 2)),
                   rstChecksum(substr($planets, 2)),
                   rstChecksum(substr($bases, 2)))
              . pack("v", $turn)
                . pack("v", rstChecksum($timestamp));
}

sub rstPackVcrs {
    my $parsedReply = shift;
    my $player = shift;
    my @vcrs;
    foreach my $vcr (@{$parsedReply->{rst}{vcrs}}) {
        my $v = pack("v*",
                     $vcr->{seed},
                     0x554E,       # 'NU', signature
                     $vcr->{right}{temperature},
                     $vcr->{battletype},
                     $vcr->{left}{mass},
                     $vcr->{right}{mass});
        foreach (qw(left right)) {
            my $o = $vcr->{$_};
            $v .= pack("A20v11",
                       $o->{name},
                       $o->{damage},
                       $o->{crew},
                       $o->{objectid},
                       $o->{raceid},
                       256*$o->{hullid} + 1,  # image, hull
                       $o->{beamid},
                       $o->{beamcount},
                       $o->{baycount},
                       $o->{torpedoid},
                       $o->{torpedoid} ? $o->{torpedos} : $o->{fighters},
                       $o->{launchercount});
        }
        $v .= pack("vv", $vcr->{left}{shield}, $vcr->{right}{shield});
        push @vcrs, $v;
    }
    pack("v", scalar(@vcrs)) . join("", @vcrs);
}

sub rstWriteMessages {
    my $nmessages = @_;

    # Write preliminary header
    my $pos = tell(RST);
    print RST 'x' x (($nmessages * 6) + 2);

    # Write messages, generating header
    my $header = pack('v', $nmessages);
    foreach (@_) {
        $header .= pack('Vv', tell(RST)+1, length($_));
        print RST $_;
    }

    # Update header
    my $pos2 = tell(RST);
    seek RST, $pos, 0;
    print RST $header;
    seek RST, $pos2, 0;
}

sub rstFormatMessage {
    # Let's play simple: since our target is PCC2 which can do word wrapping,
    # we don't have to. Just remove the HTML.
    my $text = shift;
    $text =~ s|[\s\r\n]+| |g;
    $text =~ s| *<br */?> *|\n|g;
    $text;
}

sub rstEncryptMessage {
    my $text = shift;
    my $result;
    for (my $i = 0; $i < length($text); ++$i) {
        my $ch = substr($text, $i, 1);
        if ($ch eq "\n") {
            $result .= chr(26);
        } else {
            $result .= chr(ord($ch) + 13);
        }
    }
    $result;
}

sub rstPackFields {
    my $hash = shift;
    my $pack = shift;
    my @fields;
    foreach my $field (@_) {
        push @fields, $hash->{$field};
    }
    pack($pack, @fields);
}

sub rstPackStock {
    my $baseId = shift;
    my $parsedReply = shift;
    my $stockType = shift;

    my $pStocks = $parsedReply->{rst}{stock};
    my @result;
    foreach my $id (@_) {
        # Find a stock which matches this slot
        my $found = 0;
        foreach (@$pStocks) {
            if ($_->{starbaseid} == $baseId
                && $_->{stocktype} == $stockType
                && $_->{stockid} == $id)
            {
                $found = $_->{amount};
                last;
            }
        }
        push @result, $found;
    }

    pack("v*", @result);
}

sub rstChecksum {
    my $str = shift;
    my $sum = 0;
    for (my $i = 0; $i < length($str); ++$i) {
        $sum += ord(substr($str, $i, 1));
    }
    $sum;
}

sub rstGetBaseOwner {
    my $base = shift;
    my $parsedReply = shift;
    foreach my $planet (@{$parsedReply->{rst}{planets}}) {
        if ($planet->{id} == $base->{planetid}) {
            return $planet->{ownerid};
        }
    }
    return 0;
}

sub rstMapOwnerToRace {
    my $parsedReply = shift;
    my $ownerId = shift;
    foreach my $p (@{$parsedReply->{rst}{players}}) {
        if ($p->{id} == $ownerId) {
            return $p->{raceid};
        }
    }
    return 0;
}

######################################################################
#
#  State file
#
######################################################################

my %stateValues;
my %stateChanged;

sub stateLoad {
    if (open(STATE, "< c2nu.ini")) {
        while (<STATE>) {
            s/[\r\n]*$//;
            next if /^ *#/;
            next if /^ *$/;
            if (/^(.*?)=(.*)/) {
                my $key = $1;
                my $val = $2;
                $val =~ s|\\(.)|stateUnquote($1)|eg;
                $stateValues{$key} = $val;
                $stateChanged{$key} = 0;
            } else {
                print "WARNING: state file line $. cannot be parsed\n";
            }
        }
        close STATE;
    }
}

sub stateSave {
    # Needed?
    my $needed = 0;
    foreach (keys %stateValues) {
        if ($stateChanged{$_}) {
            # print "Must update state file because '$_' has changed.\n";
            $needed = 1;
            last;
        }
    }
    return if !$needed;
    print "Updating state file...\n";

    # Copy existing file, updating it
    open(OUT, "> c2nu.new") or die "ERROR: cannot create new state file c2nu.new: $!\n";
    if (open(STATE, "< c2nu.ini")) {
        while (<STATE>) {
            s/[\r\n]*$//;
            if (/^ *#/ || /^ *$/) {
                print OUT "$_\n";
            } elsif (/^(.*?)=(.*)/ && $stateChanged{$1}) {
                my $key = $1;
                print OUT "$key=", stateQuote($stateValues{$key}), "\n";
                $stateChanged{$key} = 0;
            } else {
                print OUT "$_\n";
            }
        }
        close STATE;
    }

    # Print missing keys
    foreach (sort keys %stateValues) {
        if ($stateChanged{$_}) {
            print OUT "$_=", stateQuote($stateValues{$_}), "\n";
            $stateChanged{$_} = 0;
        }
    }
    close OUT;

    # Rename files
    unlink "c2nu.bak";
    rename "c2nu.ini", "c2nu.bak";
    rename "c2nu.new", "c2nu.ini" or print "WARNING: cannot rename new state file: $!\n";
}

sub stateSet {
    my $key = shift;
    my $val = shift;
    if (!exists($stateValues{$key}) || $stateValues{$key} ne $val) {
        $stateValues{$key} = $val;
        $stateChanged{$key} = 1;
    }
}

sub stateGet {
    my $key = shift;
    if (exists($stateValues{$key})) {
        $stateValues{$key}
    } else {
        "";
    }
}

sub stateQuote {
    my $x = shift;
    $x =~ s/\\/\\\\/g;
    $x =~ s/\n/\\n/g;
    $x =~ s/\r/\\r/g;
    $x =~ s/\t/\\t/g;
    $x =~ s/\t/\\t/g;
    $x =~ s/"/\\"/g;
    $x =~ s/'/\\'/g;
    $x;
}

sub stateUnquote {
    my $x = shift;
    if ($x eq 'n') {
        return "\n";
    } elsif ($x eq 't') {
        return "\t";
    } elsif ($x eq 'r') {
        return "\r";
    } else {
        return $x;
    }
}

sub stateCookies {
    my @cookie;
    foreach (sort keys %stateValues) {
        if (/^cookie_(.*)/) {
            push @cookie, "$1=$stateValues{$_}";
        }
    }
    join("; ", @cookie);
}

sub doStatus {
    foreach (sort keys %stateValues) {
        my $v = stateQuote($stateValues{$_});
        print "$_ =\n";
        if (length($v) > 70) {
            print "   ", substr($v, 0, 67), "...\n";
        } else {
            print "   ", $v, "\n";
        }
    }
}

######################################################################
#
#  HTTP
#
######################################################################

sub httpCall {
    # Prepare
    my ($head, $body) = @_;
    my $host = stateGet('host');
    my $keks = stateCookies();
    $head .= "Host: $host\n";
    $head .= "Content-Length: " . length($body) . "\n";
    $head .= "Connection: close\n";
    $head .= "Cookie: $keks\n" if $keks ne '';
    # $head .= "User-Agent: $0\n";
    $head =~ s/\n/\r\n/;
    $head .= "\r\n";

    # Socket cruft
    print "Calling server...\n";
    my $ip = inet_aton($host) or die "ERROR: unable to resolve host '$host': $!\n";
    my $paddr = sockaddr_in(80, $ip);
    socket(HTTP, PF_INET, SOCK_STREAM, getprotobyname('tcp')) or die "ERROR: unable to create socket: $!\n";
    binmode HTTP;
    HTTP->autoflush(1);
    connect(HTTP, $paddr) or die "ERROR: unable to connect to '$host': $!\n";

    # Send request
    print HTTP $head, $body;

    # Read reply header
    my %reply;
    while (<HTTP>) {
        s/[\r\n]*$//;
        if (/^$/) {
            last
        } elsif (m|^HTTP/\d+\.\d+ (\d+)|) {
            $reply{STATUS} = $1;
        } elsif (m|^set-cookie:\s*(.*?)=(.*?);|i) {
            $reply{"COOKIE-$1"} = $2;
        } elsif (m|^(.*?):\s+(.*)|) {
            $reply{lc($1)} = $2;
        } else {
            print STDERR "Unable to parse reply line '$_'\n";
        }
    }

    # Read reply body
    my $replybody;
    if (exists $reply{'content-length'}) {
        read HTTP, $replybody, $reply{'content-length'}
    } else {
        while (1) {
            my $tmp;
            if (!read(HTTP, $tmp, 4096)) { last }
            $replybody .= $tmp;
        }
    }
    close HTTP;

    # Check status
    if ($reply{STATUS} != 200) {
        print STDERR "WARNING: HTTP status is $reply{STATUS}.\n";
    }

    # Body might be compressed; decompress it
    if (lc($reply{'content-encoding'}) eq 'gzip') {
        print "Decompressing result...\n";
        open TMP, "> c2nu.gz" or die "Cannot open temporary file: $!\n";
        binmode TMP;
        print TMP $replybody;
        close TMP;
        $replybody = "";
        open TMP, "gzip -dc c2nu.gz |" or die "Cannot open gzip: $!\n";
        binmode TMP;
        while (1) {
            my $tmp;
            if (!read(TMP, $tmp, 4096)) { last }
            $replybody .= $tmp;
        }
        close TMP;
    }

    $reply{BODY} = $replybody;
    \%reply;
}

sub httpEscape {
    my $x = shift;
    $x =~ s/([&+%\r\n])/sprintf("%%%02X", ord($1))/eg;
    $x =~ s/ /+/g;
    $x;
}

sub httpBuildQuery {
    my @list;
    while (@_) {
        my $key = shift @_;
        my $val = shift @_;
        push @list, "$key=" . httpEscape($val);
    }
    join('&', @list);
}

######################################################################
#
#  JSON
#
######################################################################

sub jsonParse {
    my $str = shift;
    pos($str) = 0;
    jsonParse1(\$str);
}

sub jsonParse1 {
    my $pstr = shift;
    $$pstr =~ m|\G\s*|sgc;
    if ($$pstr =~ m#\G"(([^\\"]+|\\.)*)"#gc) {
        my $s = $1;
        $s =~ s|\\(.)|stateUnquote($1)|eg;
        # Nu data is in UTF-8. Translate what we can to latin-1, because
        # PCC does not handle UTF-8 in game files. Doing it here conveniently
        # handles all places with possible UTF-8, including ship names,
        # messages, and notes.
        utf8ToLatin1($s);
    } elsif ($$pstr =~ m|\G([-+]?\d+\.\d*)|gc) {
        $1;
    } elsif ($$pstr =~ m|\G([-+]?\.\d+)|gc) {
        $1;
    } elsif ($$pstr =~ m|\G([-+]?\d+)|gc) {
        $1;
    } elsif ($$pstr =~ m|\Gtrue\b|gc) {
        1
    } elsif ($$pstr =~ m|\Gfalse\b|gc) {
        0
    } elsif ($$pstr =~ m|\Gnull\b|gc) {
        undef
    } elsif ($$pstr =~ m|\G\{|gc) {
        my $result = {};
        while (1) {
            $$pstr =~ m|\G\s*|sgc;
            if ($$pstr =~ m|\G\}|gc) { last }
            elsif ($$pstr =~ m|\G,|gc) { }
            else {
                my $key = jsonParse1($pstr);
                $$pstr =~ m|\G\s*|sgc;
                if ($$pstr !~ m|\G:|gc) { die "JSON syntax error: expecting ':', got '" . substr($$pstr, pos($$pstr), 20) . "'.\n" }
                my $val = jsonParse1($pstr);
                $result->{$key} = $val;
            }
        }
        $result;
    } elsif ($$pstr =~ m|\G\[|gc) {
        my $result = [];
        while (1) {
            $$pstr =~ m|\G\s*|sgc;
            if ($$pstr =~ m|\G\]|gc) { last }
            elsif ($$pstr =~ m|\G,|gc) { }
            else { push @$result, jsonParse1($pstr) }
        }
        $result;
    } else {
        die "JSON syntax error: expecting element, got '" . substr($$pstr, pos($$pstr), 20) . "'.\n";
    }
}

sub jsonDump {
    my $tree = shift;
    my $prefix = shift;
    my $indent = "$prefix    ";
    if (ref($tree) eq 'ARRAY') {
        # Array.
        if (@$tree == 0) {
            # Empty
            print "[]";
        } elsif (grep {ref or /\D/} @$tree) {
            # Full form
            print "[\n$indent";
            my $i = 0;
            foreach (@$tree) {
                print ",\n$indent" if $i;
                $i = 1;
                jsonDump($_, $indent);
            }
            print "\n$prefix]";
        } else {
            # Short form
            print "[";
            my $i = 0;
            foreach (@$tree) {
                if ($i > 20) {
                    print ",\n$indent";
                    $i = 0;
                } else {
                    print "," if $i;
                    ++$i;
                }
                jsonDump($_, $indent);
            }
            print "]";
        }
    } elsif (ref($tree) eq 'HASH') {
        # Hash
        print "{";
        my $i = 0;
        foreach (sort keys %$tree) {
            print "," if $i;
            $i = 1;
            print "\n$indent\"", stateQuote($_), "\": ";
            jsonDump($tree->{$_}, $indent);
        }
        print "\n$prefix" if $i;
        print "}";
    } else {
        # scalar
        if (!defined($tree)) {
            print "null";
        } elsif ($tree =~ /^-?\d+$/) {
            print $tree;
        } else {
            $tree =~ s/([\\\"])/\\$1/g;
            print '"', stateQuote($tree), '"';
        }
    }
}

######################################################################
#
#  XML
#
######################################################################

# DOM:
#   a document is a list of items.
#   an item is a string or a tag.
#   a tag is an embedded hash:
#     TAG => tag name
#     CONTENT => content, reference to a document
#     name => attribute

sub xmlParse {
    my $str = shift;
    pos($str) = 0;
    my @stack = ({CONTENT=>[]});
    while (1) {
        if ($str =~ m|\G$|) {
            last
        } elsif ($str =~ m|\G</(\w+)>|gc) {
            if (!exists($stack[-1]->{TAG}) || $stack[-1]->{TAG} ne $1) {
                die "XML syntax error: got '</$1>' while expecting another\n";
            }
            pop @stack;
        } elsif ($str =~ m|\G<!--.*?-->|gc) {
            # Comment
        } elsif ($str =~ m|\G<(\w+)\s*|gc) {
            # Opening tag
            my $t = {TAG=>$1, CONTENT=>[]};
            push @{$stack[-1]->{CONTENT}}, $t;
            push @stack, $t;

            # Read attributes
            while ($str =~ m|\G(\w+)\s*=\"([^"]*)\"\s*|gc || $str =~ m|\G(\w+)\s*=\'([^']*)\'\s*|gc) {       #"){
                $t->{lc($1)} = xmlUnquote($2);
            }

            # Close
            if ($str =~ m|\G/\s*>|gc) {
                pop @stack;
            } elsif ($str =~ m|\G>|gc) {
                # keep
            } else {
                die "XML syntax error: got '" . substr($str, pos($str), 20) . "' while expecting tag end\n";
            }
        } elsif ($str =~ m|\G([^<]+)|sgc) {
            push @{$stack[-1]->{CONTENT}}, xmlUnquote($1);
        } else {
            die "XML syntax error: got '" . substr($str, pos($str), 20) . "' while expecting tag or text\n";
        }
    }
    $stack[0];
}

sub xmlUnquote {
    my $str = shift;
    $str =~ s|&(.*?);|xmlEntity($1)|eg;
    $str;
}

sub xmlEntity {
    my $x = shift;
    if ($x eq 'lt') { return "<" }
    if ($x eq 'gt') { return ">" }
    if ($x eq 'amp') { return "&" }
    if ($x eq 'quot') { return "\"" }
    if ($x eq 'apos') { return "'" }
    if ($x =~ /^\#(\d+)/) { return chr($1) }
    if ($x =~ /^\#x([0-9a-f]+)/i) { return chr(hex($1)) }
    return "?";
}

sub xmlPrint {
    my $xml = shift;
    my $indent = shift || "";
    if (exists $xml->{TAG}) {
        print "$indent <$xml->{TAG}>\n";
        foreach my $k (sort keys %$xml) {
            print "$indent   \@$k=$xml->{$k}\n"
                unless $k eq 'TAG' || $k eq 'CONTENT';
        }
    } else {
        print "$indent ROOT\n";
    }
    foreach (@{$xml->{CONTENT}}) {
        if (ref) {
            xmlPrint($_, "$indent    ");
        } else {
            print "$indent     \"$_\"\n";
        }
    }
}

# xmlDirectChildren($tag, @list)
#   Given a list of items, extract all that have a particular tag name.
#   Somehow like XPath "<list>/tag".
sub xmlDirectChildren {
    my $tag = shift;
    grep {ref($_) && $_->{TAG} eq $tag} @_;
}

# xmlIndirectChildren($tag, @list)
#   Like xmlDirectChildren, but searches indirect children as well.
#   Somehow like XPath "<list>//tag".
sub xmlIndirectChildren {
    my $tag = shift;
    my @result;
    foreach (@_) {
        if (ref($_)) {
            if (exists($_->{TAG}) && $_->{TAG} eq $tag) {
                push @result, $_
            } else {
                push @result, xmlIndirectChildren($tag, @{$_->{CONTENT}});
            }
        }
    }
    @result;
}

# Given a list of tags, merge its content into one list
sub xmlMergeContent {
    my @result;
    foreach (@_) {
        push @result, @{$_->{CONTENT}};
    }
    @result;
}

# Find content.
sub xmlTextContent {
    join ('', grep {!ref($_)} @_);
}

######################################################################
#
#  Utilities
#
######################################################################

sub replicate {
    my $n = shift;
    my @result;
    foreach (1 .. $n) { push @result, @_ }
    @result;
}

sub sequence {
    my $a = shift;
    my $b = shift;
    my @result;
    while ($b > 0) {
        push @result, $a++;
        --$b;
    }
    @result;
}

sub utf8ToLatin1 {
    my $s = shift;
    $s =~ s/([\xC0-\xC3])([\x80-\xBF])/chr(((ord($1) & 3) << 6) + (ord($2) & 63))/eg;
    $s;
}
