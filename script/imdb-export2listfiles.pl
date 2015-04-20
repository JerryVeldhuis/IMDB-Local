#!/usr/bin/perl 

#
# perl -Iblib/lib script/test-export-listfiles.pl --imdb db --listsDir tmp/lists --file ../titles4testing.txt  && perl -Iblib/lib script/imdb-local.pl -imdb tmp --import all
#
use strict;
use warnings;
use Getopt::Long;

use IMDB::Local;
use IMDB::Local::Title;

use Cwd;

my $opt_imdbDir=getcwd();
my $opt_help;
my $opt_quiet=0;
my $opt_force=0;
my $opt_file;
my $opt_listsDir;

GetOptions('help'            => \$opt_help,
	   'imdbdir=s'       => \$opt_imdbDir,
	   'file=s'          => \$opt_file,
	   'listsDir=s'      => \$opt_listsDir,
	   'quiet'           => \$opt_quiet
    ) or usage(0);

if ( $opt_help ) {
    die "no usage implemented";
}

$opt_quiet=(defined($opt_quiet));

# lets put list files below the imdbDir
if ( !defined($opt_listsDir) ) {
    $opt_listsDir="$opt_imdbDir/lists";
}

# lets put list files below the imdbDir
if ( !defined($opt_file) ) {
    die "missing --file <file>"
}

my $db=new IMDB::Local::DB(database=>"$opt_imdbDir/imdb.db");
if ( !$db->connect() ) {
    die "moviedb connect failed:$DBI::errstr";
}

my @titleIds;

if ( open(my $fd, "< $opt_file") ) {
    while(<$fd>) {
	chomp();
	
	s/^\s+//o;
	s/\s+$//o;
	next if ( ! length() );
	next if ( m/^#/ );

	my $sql;
	
	if ( m/%/o ) {
	    $sql="select TitleID from Titles where Title like ".$db->quote($_)."";
	}
	else {
	    $sql="select TitleID from Titles where Title=".$db->quote($_)."";
	}

	print STDERR "running: $sql\n"; 

	my $res=$db->select2Array($sql);
	if ( $res ) {
	    print STDERR "   hit ".scalar(@$res)." Titles\n";
	    push(@titleIds, @$res);
	}
	else {
	    warn("no matching titles for '$_'");
	}
    }
    close($fd);
}

print STDERR "found ".scalar(@titleIds)." Titles\n";

my %found;

for my $titleId (@titleIds) {
    my $t=IMDB::Local::Title::findByTitleID($db, $titleId);
    if ( !$t ) {
	die "unable to retrieve existing TitleID:$titleId";
    }
    if ( $t->QualifierTypeID == IMDB::Local::QualifierType::TV_SERIES ||
	 $t->QualifierTypeID == IMDB::Local::QualifierType::TV_MOVIE ||
	 $t->QualifierTypeID == IMDB::Local::QualifierType::MOVIE ) {
	$found{$titleId}=$t;
	
    }
}

for my $t (grep {$_->QualifierTypeID == IMDB::Local::QualifierType::TV_SERIES} values %found) {
    my $res=$db->select2Array("select TitleID from Titles where ParentID=".$t->TitleID);
    if ( ! $res ) {
	die "unable to locate any series titles matching TitleID:".$t->TitleID;
    }
    
    for my $titleId (@$res) {
	$found{$titleId}=IMDB::Local::Title::findByTitleID($db, $titleId);
	#print "added $titleId: ".$found{$titleId}->Title."\n";
    }
}
print STDERR "added tv series episodes, now have ".scalar(keys %found)." Titles\n";


if ( open(my $fd, "> $opt_listsDir/movies.list") ) {
    print $fd "MOVIES LIST\n";
    print $fd "===========\n\n";
    
    # "#ATown" (2014)                                         2014-????
    # "#ATown" (2014) {Best Friends Day (#1.10)}              2014
    # "#ATown" (2014) {Chicks in Pink, Vomit in a Sink (#1.6)}        2014
    # "#ATown" (2014) {Dunzo (#1.9)}                          2014

    for my $t (grep {$_->QualifierTypeID == IMDB::Local::QualifierType::TV_SERIES} values %found) {
	my $mkey=sprintf "\"%s\" (%04d)", $t->Title, $t->Year;
	printf $fd "%s\t\t%04d\n", $mkey, $t->Year;
	
	my $res=$db->select2Matrix("select TitleID,Title,Series,Episode,AirDate from Titles where ParentID=".$t->TitleID." order by Series,Episode");
	if ( ! $res ) {
	    die "unable to locate any series titles matching TitleID:".$t->TitleID;
	}

	for my $row (@$res) {
	    my ($titleId, $title, $series, $episode, $airdate)=@$row;
	    if ( $series != 0 && $episode != 0 ) {
		my $mkey=sprintf "\"%s\" (%04d) {%s (#%d.%d)}", $t->Title, $t->Year, $title, $series, $episode;
		printf $fd "%s\t\t%04d\n", $mkey, $t->Year;
	    }
	    else {
		my $mkey=sprintf "\"%s\" (%04d) {%s}", $t->Title, $t->Year, $title, $airdate;
		printf $fd "%s\t\t%04d\n", $mkey, $t->Year;
	    }
	}
    }
    for my $t (grep {$_->QualifierTypeID == IMDB::Local::QualifierType::TV_MOVIE} values %found) {
	my $mkey=sprintf "%s (%04d)", $t->Title, $t->Year;
	printf $fd "%s\t\t%04d\n", $mkey, $t->Year;
    }
    for my $t (grep {$_->QualifierTypeID == IMDB::Local::QualifierType::MOVIE} values %found) {
	my $mkey=sprintf "%s (%04d)", $t->Title, $t->Year;
	printf $fd "%s\t\t%04d\n", $mkey, $t->Year;
    }
    close($fd);
}

sub GetIMDBKey($)
{
    
    my ($t)=@_;

    my $mkey;

    #print "adding $name: ".$t->QualifierTypeID."\n";
    if ( $t->QualifierTypeID == IMDB::Local::QualifierType::EPISODE_OF_TV_SERIES ) {
	my $parent=$found{$t->ParentID};
	
	if ( $t->Series != 0 && $t->Episode != 0 ) {
	    $mkey=sprintf "\"%s\" (%04d) {%s (#%d.%d)}", $parent->Title, $parent->Year, $t->Title, $t->Series, $t->Episode;
	}
	else {
	    $mkey=sprintf "\"%s\" (%04d) {%s}", $parent->Title, $parent->Year, $t->Title, $t->AirDate;
	}
    }
    else {
	$mkey = sprintf "%s (%04d)", $t->Title, $t->Year;
    }
    return($mkey);
}

if ( open(my $fd, "> $opt_listsDir/directors.list") ) {
    print $fd "THE DIRECTORS LIST\n";
    print $fd "==================\n\n";
    print $fd "Name Titles\n\n";
    
    my %directors;

    for my $k (sort keys %found) {
	my $t=$found{$k};

	my $res=$db->select2Matrix("select Directors.DirectorID,Directors.Name,TitleID from ".
				   "Directors join Titles2Directors on Directors.DirectorID=Titles2Directors.DirectorID ".
				   "where Titles2Directors.TitleID=".$t->TitleID."");
	if ( ! $res ) {
	    die "unable to search for directors TitleID:".$t->TitleID;
	}
	for my $row (@$res) {
	    my ($directorID, $name, $titleid)=@$row;
	    push(@{$directors{$name}}, $row);
	    #print "".$t->Title.": $name\n";
	}
    }

    for my $name (sort keys %directors) {

	#
	# lets grab the titles
	#

	my @titles;
	for my $row (@{$directors{$name}}) {
	    my ($directorID, $name, $titleid)=@$row;
	    push(@titles, $found{$titleid});
	}
	
	for (my $c=0; $c<scalar(@titles); $c++) {
	    my $t=$titles[$c];
	    
	    my $mkey=GetIMDBKey($t);
	    if ( $c == 0 ) {
		printf $fd "%-25s\t%s\n", $name, $mkey;
	    }
	    else {
		printf $fd "%-25s\t%s\n", '', $mkey;
	    }
	}
    }
    
    close($fd);
}


if ( open(my $fd, "> $opt_listsDir/actors.list") ) {
    print $fd "THE ACTORS LIST\n";
    print $fd "================\n\n";
    print $fd "Name Titles\n\n";
    
    my %actors;

    for my $k (sort keys %found) {
	my $t=$found{$k};

	my $res=$db->select2Matrix("select Actors.ActorID,Actors.Name,TitleID from ".
				   "Actors join Titles2Actors on Actors.ActorID=Titles2Actors.ActorID ".
				   "where Titles2Actors.TitleID=".$t->TitleID."");
	if ( ! $res ) {
	    die "unable to search for actors TitleID:".$t->TitleID;
	}
	for my $row (@$res) {
	    my ($actorID, $name, $titleid)=@$row;
	    push(@{$actors{$name}}, $row);
	}
    }

    for my $name (sort keys %actors) {

	#
	# lets grab the titles
	#
	my @titles;
	for my $row (@{$actors{$name}}) {
	    my ($actorID, $name, $titleid)=@$row;
	    push(@titles, $found{$titleid});
	}
	
	for (my $c=0; $c<scalar(@titles); $c++) {
	    my $t=$titles[$c];

	    my $mkey=GetIMDBKey($t);
	    if ( $c == 0 ) {
		printf $fd "%-25s\t%s\n", $name, $mkey;
	    }
	    else {
		printf $fd "%-25s\t%s\n", '', $mkey;
	    }
	}
    }
    
    close($fd);
}

if ( open(my $fd, "> $opt_listsDir/genres.list") ) {
    print $fd "8: THE GENRES LIST\n";
    print $fd "==================\n\n";
    

    for my $t (sort keys %found) {
	my $title=$found{$t};

	my $mkey=GetIMDBKey($title);

	$title->populateGenres();

	for my $g ( $title->Genres ) {
	    printf $fd "%-50s\t%s\n", $mkey, $g->Name;
	}
    }

    close($fd);
}


exit(0);
