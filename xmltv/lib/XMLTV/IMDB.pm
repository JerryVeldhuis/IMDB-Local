#
# $Id: IMDB.pm,v 1.67 2015/03/11 03:33:09 jveldhuis Exp $
#
# The IMDB file contains two packages:
# 1. XMLTV::IMDB::Cruncher package which parses and manages IMDB "lists" files
#    from ftp.imdb.com
# 2. XMLTV::IMDB package that uses data files from the Cruncher package to
#    update/add details to XMLTV programme nodes.
#
# BUG - if there is a matching title with > 1 entry (say made for tv-movie and
#       at tv-mini series) made in the same year (or even "close" years) it is
#       possible for us to pick the wrong one we should pick the one with the
#       closest year, not just the first closest match based on the result ordering
#       for instance Ghost Busters was made in 1984, and into a tv series in
#       1986. if we have a list of GhostBusters 1983, we should pick the 1984 movie
#       and not 1986 tv series...maybe :) but currently we'll pick the first
#       returned close enough match instead of trying the closest date match of
#       the approx hits.
#

use strict;

package XMLTV::IMDB;

use open ':encoding(iso-8859-1)'; # try to enforce file encoding (does this work in Perl <5.8.1? )

use IMDB::Local::Title;
use IMDB::Local::QualifierType ':types';

#
# HISTORY
# .6 = what was here for the longest time
# .7 = fixed file size est calculations
#    = moviedb.info now includes _file_size_uncompressed values for each downloaded file
# .8 = updated file size est calculations
#    = moviedb.dat directors and actors list no longer include repeated names (which mostly
#      occured in episodic tv programs (reported by Alexy Khrabrov)
# .9 = added keywords data
# .10 = added plot data
#
our $VERSION = '1.10';      # version number of database

use constant OP_NO_UPDATE          => 0x0;
use constant OP_UPDATE             => 0x1;
use constant OP_REPLACE            => 0x2;

#use constant REPLACE_EXISTING   => 4;

sub new
{
    my ($type) = shift;
    my $self={ @_ };            # remaining args become attributes

    for ('imdbDir', 'verbose') {
	die "invalid usage - no $_" if ( !defined($self->{$_}));
    }

    # setup-defaults
    $self->{op}->{Dates}       =(OP_UPDATE|OP_REPLACE);
    $self->{op}->{Titles}      =(OP_NO_UPDATE);
    $self->{op}->{URLs}        =(OP_UPDATE);
    $self->{op}->{Directors}   =(OP_UPDATE|OP_REPLACE);
    $self->{op}->{Actors}      =(OP_UPDATE);
    $self->{op}->{Presenters}  =(OP_UPDATE);
    $self->{op}->{Commentators}=(OP_UPDATE);
    $self->{op}->{Categories}  =(OP_UPDATE);
    $self->{op}->{Keywords}    =(OP_NO_UPDATE);
    $self->{op}->{StarRating}  =(OP_UPDATE);
    $self->{op}->{Description} =(OP_NO_UPDATE);

    #$self->{verbose}=2;
    for my $flag ('Dates', 'Titles', 'URLs', 'Directors', 'Actors', 
		  'Presenters', 'Commentators', 'Categories',
		  'Keywords', 'StarRating', 'Description') {
	my $f=delete($self->{$flag."-behaviour"});
	if ( defined($f) ) {
	    $self->{op}->{$flag}=$f;
	}
	
    }

    $self->{updateCategoriesWithGenres}=1 if ( !defined($self->{updateCategoriesWithGenres}));

    $self->{numActors}=3          if ( !defined($self->{numActors}));           # default is to add top 3 actors
    
    $self->{moviedb}=new IMDB::Local::DB(database=>$self->{imdbDir}."/imdb.db");

    $self->{moviedbInfo}   ="$self->{imdbDir}/moviedb.info";
    $self->{moviedbOffline}="$self->{imdbDir}/moviedb.offline";
    
    $self->{categories}={IMDB::Local::QualifierType::MOVIE       =>'Movie',
			 IMDB::Local::QualifierType::TV_MOVIE    =>'TV Movie', # made for tv
			 IMDB::Local::QualifierType::VIDEO_MOVIE =>'Video Movie', # went straight to video or was made for it
			 IMDB::Local::QualifierType::TV_SERIES   =>'TV Series',
			 IMDB::Local::QualifierType::TV_MINI_SERIES   =>'TV Mini Series'};

    $self->{stats}->{programCount}=0;

    for my $cat (keys %{$self->{categories}}) {
	$self->{stats}->{perfect}->{$cat}=0;
	$self->{stats}->{close}->{$cat}=0;
    }
    $self->{stats}->{perfectMatches}=0;
    $self->{stats}->{closeMatches}=0;

    $self->{stats}->{startTime}=time();

    bless($self, $type);
    return($self);
}

sub _NOT_USED_basicVerificationOfIndexes($)
{
    my $self=shift;

    # check that the imdbdir is invalid and up and running
    my $title="Army of Darkness";
    my $year=1992;

    $self->openMovieIndex() || return("basic verification of indexes failed\n".
				      "database index isn't readable");

    my $verbose = $self->{verbose}; $self->{verbose} = 0; 
    my $res=$self->getTitleMatches($title, $year, IMDB::Local::QualifierType::MOVIE);
    $self->{verbose} = $verbose; undef $verbose;
    if ( !defined($res) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "no match for basic verification of movie \"$title, $year\"\n");
    }
    if ( !defined($res->{exactMatch}) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "no exact match for movie \"$title, $year\"\n");
    }
    if ( scalar(@{$res->{exactMatch}})!= 1) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "got more than one exact match for movie \"$title, $year\"\n");
    }
    my @exact=@{$res->{exactMatch}};
    if ( $exact[0]->{title} ne $title ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "title associated with key \"$title, $year\" is bad\n");
    }

    if ( $exact[0]->{year} ne "$year" ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "year associated with key \"$title, $year\" is bad\n");
    }

    my $id=$exact[0]->{id};
    #$res=$self->getMovieIdDetails($id);
    if ( !defined($res) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "no movie details for movie \"$title, $year\" (id=$id)\n");
    }
    
    if ( !defined($res->{directors}) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't provide any director for movie \"$title, $year\" (id=$id)\n");
    }
    if ( !$res->{directors}[0]=~m/Raimi/o ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't show Raimi as the main director for movie \"$title, $year\" (id=$id)\n");
    }
    if ( !defined($res->{actors}) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't provide any cast movie \"$title, $year\" (id=$id)\n");
    }
    if ( !$res->{actors}[0]=~m/Campbell/o ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't show Bruce Campbell as the main actor in movie \"$title, $year\" (id=$id)\n");
    }
    my $matches=0;
    for (@{$res->{genres}}) {
	if ( $_ eq "Action" ||
	     $_ eq "Comedy" ||
	     $_ eq "Fantasy" ||
	     $_ eq "Horror" ||
	     $_ eq "Romance" ) {
	    $matches++;
	}
    }
    if ( $matches == 0 ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't show genres correctly for movie \"$title, $year\" (id=$id)\n");
    }
    if ( !defined($res->{ratingDist}) ||
	 !defined($res->{ratingVotes}) ||
	 !defined($res->{ratingRank}) ) {
	$self->closeMovieIndex();
	return("basic verification of indexes failed\n".
	       "movie details didn't show imdbratings for movie \"$title, $year\" (id=$id)\n");
    }
    $self->closeMovieIndex();
    return(undef);

}

sub error($$)
{
    print STDERR "tv_imdb: $_[1]\n";
}

sub status($$)
{
    if ( $_[0]->{verbose} ) {
	#print STDERR "tv_imdb: $_[1]\n";
	print STDOUT "tv_imdb: $_[1]\n";
    }
}

sub debug($$)
{
    my $self=shift;
    my $mess=shift;
    if ( $self->{verbose} > 1 ) {
	#print STDERR "tv_imdb: $mess\n";
	print STDOUT "tv_imdb: $mess\n";
    }
}

use Search::Dict;

sub openMovieIndex($)
{
    my $self=shift;

    if ( !$self->{moviedb}->connect() ) {
	return(undef);
    }
    return(1);
}

sub closeMovieIndex($)
{
    my $self=shift;

    if ( !$self->{moviedb}->disconnect() ) {
	return(undef);
    }
    return(1);
}


sub searchTitlesWithCache($$$)
{
    my ($self, $searchableTItle, $qualifierTypeID)=@_;

    if ( $self->{searchCache}->{"$searchableTItle, $qualifierTypeID"} ) {
	return $self->{searchCache}->{"$searchableTItle, $qualifierTypeID"};
    }
    else {
	my @list=IMDB::Local::Title::findBySearchableTitle($self->{moviedb}, $searchableTItle, $qualifierTypeID);
	$self->{searchCache}->{"$searchableTItle, $qualifierTypeID"}=\@list;
	return \@list;
    }
}

sub findTitleWithCache($$)
{
    my ($self, $titleId)=@_;
    
    if ( $self->{titleCache}->{$titleId} ) {
	return $self->{titleCache}->{$titleId};
    }
    else {
	my $t=IMDB::Local::Title::findByTitleID($self->{moviedb}, $titleId);;
	$self->{titleCache}->{$titleId}=$t;
	return $t;
    }
}

# moviedbIndex file has the format:
# title:lineno
# where key is a url encoded title followed by the year of production and a colon
sub getTitleMatches($$$$)
{
    my ($self, $title, $year, $qualifierTypeID)=@_;

    # Articles are put at the end of a title ( in all languages )
    #$match=~s/^(The|A|Une|Las|Les|Los|L\'|Le|La|El|Das|De|Het|Een)\s+(.*)$/$2, $1/og;
    
    my $searchableTItle=$self->{moviedb}->makeSearchableTitle($title);

    my @results;

    #my @list=IMDB::Local::Title::findBySearchableTitle($self->{moviedb}, $searchableTItle, $qualifierTypeID);
    my @list=@{$self->searchTitlesWithCache($searchableTItle, $qualifierTypeID)};
    for my $i (@list) {
	#my $t=IMDB::Local::Title::findByTitleID($self->{moviedb}, $i);
	my $t=$self->findTitleWithCache($i);
	if ( ! $t ) {
	    warn "unable to find title $i";
	    next;
	}

	my $exact=0;
	if ( $t->Title() eq $title ) {
	    if ( defined($year) && $t->Year != 0 && $year == $t->Year) {
		$exact++;
	    }
	}

	if ( $exact ) {
	    $self->debug("exact match on: $i:".$t->Title().", year=".$t->Year);
	}
	else {
	    $self->debug("close match on: $i:".$t->Title().", year=".$t->Year);
	}
	     
	push(@results, {'key'=>"TitleID:".$t->TitleID."(".$t->Title.")",
			'TitleObj'=>$t,
			'title'=>$title,
			'year'=>$t->Year,
			'YearMatched'=>$exact});
    }
    return(\@results);
}


#
# FUTURE - close hit could be just missing or extra
#          punctuation:
#       "Run Silent, Run Deep" for imdb's "Run Silent Run Deep"
#       "Cherry, Harry and Raquel" for imdb's "Cherry, Harry and Raquel!"
#       "Cat Women of the Moon" for imdb's "Cat-Women of the Moon"
#       "Baywatch Hawaiian Wedding" for imdb's "Baywatch: Hawaiian Wedding" :)
#
#
sub findMovieInfo($$$$)
{
    my ($self, $title, $year, $exact)=@_;

    # try an exact match first :)
    if ( $exact == 1 ) {
	my $res=$self->getTitleMatches($title, $year, IMDB::Local::QualifierType::MOVIE);
	next if ( ! defined($res) );
	
	for my $info (@$res) {
	    next if ( ! $info->{YearMatched} );

	    my $qualifierID=$info->{TitleObj}->QualifierTypeID;
	    
	    if ( $qualifierID == IMDB::Local::QualifierType::MOVIE ) {
		$self->status("perfect hit on movie \"$info->{key}\"");
		$info->{matchLevel}="perfect";
		return($info); 
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MOVIE) {
		$self->status("perfect hit on made-for-tv-movie \"$info->{key}\"");
		$info->{matchLevel}="perfect";
		return($info); 
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_MOVIE ) {
		$self->status("perfect hit on made-for-video-movie \"$info->{key}\"");
		$info->{matchLevel}="perfect";
		return($info); 
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_GAME ) {
		next;
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::TV_SERIES ) {
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MINI_SERIES ) {
	    }
	    else {
		$self->error("$self->{moviedbIndex} responded with wierd entry for \"$info->{key}\"");
		$self->error("weird trailing qualifier \"$qualifierID\"");
		$self->error("submit bug report to xmltv-devel\@lists.sf.net");
	    }
	}
	$self->debug("no exact title/year hit on \"$title ($year)\"");
	return(undef);
    }

    if ( $exact == 2 ) {
	# looking for first exact match on the title, don't have a year to compare

	# try close hit if only one :)
	my $cnt=0;

	my $res=$self->getTitleMatches($title, undef, IMDB::Local::QualifierType::MOVIE);
	next if ( ! defined($res) );
	
	for my $info (@$res) {
	    #next if ( $info->{YearMatched} );
	    
	    $cnt++;
	    
	    # within one year with exact match good enough
	    if ( lc($title) eq lc($info->{title}) ) {
		
		my $qualifierID=$info->{TitleObj}->QualifierTypeID;

		if ( $qualifierID == IMDB::Local::QualifierType::MOVIE ) {
		    $self->status("close enough hit on movie \"$info->{key}\" (since no 'date' field present)");
		    $info->{matchLevel}="close";
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MOVIE) {
		    $self->status("close enough hit on made-for-tv-movie \"$info->{key}\" (since no 'date' field present)");
		    $info->{matchLevel}="close";
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_MOVIE ) {
		    $self->status("close enough hit on made-for-video-movie \"$info->{key}\" (since no 'date' field present)");
		    $info->{matchLevel}="close";
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_GAME ) {
		    next;
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_SERIES ) {
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MINI_SERIES ) {
		}
		else {
		    $self->error("$self->{moviedbIndex} responded with wierd entry for \"$info->{key}\"");
		    $self->error("weird trailing qualifier \"$qualifierID\"");
		    $self->error("submit bug report to xmltv-devel\@lists.sf.net");
		}
	    }
	}
	# nothing worked
	return(undef);
    }

    # otherwise we're looking for a title match with a close year
	# try close hit if only one :)
    my $cnt=0;
    my $res=$self->getTitleMatches($title, undef, 0); #any type
    next if ( ! defined($res) );
    
    for my $info (@$res) {
	#next if ( $info->{YearMatched} );
	#next if ( !defined($info) );
	$cnt++;
	
	# within one year with exact match good enough
	if ( lc($title) eq lc($info->{title}) ) {
	    my $yearsOff=abs(int($info->{year})-$year);
	    
	    $info->{matchLevel}="close";
	    
	    if ( $yearsOff <= 2 ) {
		my $showYear=int($info->{year});
		
		#if ( ! defined($info->{TitleObj}->QualifierType()) ) {
		#if ( ! $info->{TitleObj}->populateQualifierType() ) {
		#die "unable to locate qualifiertype for ".$info->{TitleObj}->TitleID;
		#}
		#}
		
		my $qualifierID=$info->{TitleObj}->QualifierTypeID;
		
		if ( $qualifierID == IMDB::Local::QualifierType::MOVIE ) {
		    $self->status("close enough hit on movie \"$info->{key}\" (off by $yearsOff years)");
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MOVIE) {
		    $self->status("close enough hit on made-for-tv-movie \"$info->{key}\" (off by $yearsOff years)");
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_MOVIE ) {
		    $self->status("close enough hit on made-for-video-movie \"$info->{key}\" (off by $yearsOff years)");
		    return($info); 
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_GAME ) {
		    $self->status("ignoring close hit on video-game \"$info->{key}\"");
		    next;
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_SERIES ) {
		    $self->status("ignoring close hit on tv series \"$info->{key}\"");
		    #$self->status("close enough hit on tv series \"$info->{key}\" (off by $yearsOff years)");
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MINI_SERIES ) {
		    $self->status("ignoring close hit on tv mini-series \"$info->{key}\"");
		    #$self->status("close enough hit on tv mini-series \"$info->{key}\" (off by $yearsOff years)");
		}
		else {
		    $self->error("$self->{moviedbIndex} responded with wierd entry for \"$info->{key}\"");
		    $self->error("weird trailing qualifier \"$qualifierID\"");
		    $self->error("submit bug report to xmltv-devel\@lists.sf.net");
		}
	    }
	}
    }
	
    # if we found at least something, but nothing matched
    # produce warnings about missed, but close matches
    for my $info (@$res) {
	#next if ( $info->{YearMatched} );
	
	# within one year with exact match good enough
	if ( lc($title) eq lc($info->{title}) ) {
	    my $yearsOff=abs(int($info->{year})-$year);
	    if ( $yearsOff <= 2 ) {
		#die "internal error: key \"$info->{key}\" failed to be processed properly";
	    }
	    elsif ( $yearsOff <= 5 ) {
		# report these as status
		$self->status("ignoring close, but not good enough hit on \"$info->{key}\" (off by $yearsOff years)");
	    }
	    else {
		# report these as debug messages
		$self->debug("ignoring close hit on \"$info->{key}\" (off by $yearsOff years)");
	    }
	}
	else {
	    $self->debug("ignoring close hit on \"$info->{key}\" (title did not match)");
	}
    }

    #$self->status("failed to lookup \"$title ($year)\"");
    return(undef);
}

sub findTVSeriesInfo($$)
{
    my ($self, $title)=@_;

    # try close hit if only one :)
    for my $qualifierId (IMDB::Local::QualifierType::TV_SERIES, 
			 IMDB::Local::QualifierType::TV_MINI_SERIES) {

	my $res=$self->getTitleMatches($title, undef, $qualifierId);
    
	for my $info (@$res) {
	    if ( lc($title) eq lc($info->{title}) ) {
	    
		$info->{matchLevel}="perfect";
		
		my $qualifierID=$info->{TitleObj}->QualifierTypeID;
		
		if ( $qualifierID == IMDB::Local::QualifierType::TV_SERIES ) {
		    $self->status("perfect hit on tv series \"$info->{key}\"");
		    return($info);
		}
		elsif ( $qualifierID == IMDB::Local::QualifierType::TV_MINI_SERIES ) {
		    $self->status("perfect hit on tv mini-series \"$info->{key}\"");
		    return($info);
		}
	    }
	}
    }

    #$self->status("failed to lookup tv series \"$title\"");
    return(undef);
}

#
# todo - add country of origin
# todo - video (colour/aspect etc) details
# todo - audio (stereo) details 
# todo - ratings ? - use certificates.list
# todo - add description - plot summaries ? - which one do we choose ?
# todo - writer
# todo - producer
# todo - running time (duration)
# todo - identify 'Host' and 'Narrator's and put them in as
#        credits:presenter and credits:commentator resp.
# todo - check program length - probably a warning if longer ?
#        can we update length (separate from runnning time in the output ?)
# todo - icon - url from www.imdb.com of programme image ?
#        this could be done by scraping for the hyper linked poster
#        <a name="poster"><img src="http://ia.imdb.com/media/imdb/01/I/60/69/80m.jpg" height="139" width="99" border="0"></a>
#        and grabbin' out the img entry. (BTW ..../npa.jpg seems to line up with no poster available)
#
#
sub applyFound($$$)
{
    my ($self, $prog, $idInfo)=@_;

    my $title=$prog->{title}->[0]->[0];

    #if ( !defined($idInfo->{TitleObj}->QualifierType()) ) {
    #die "here";
    #}
    my $qualifierID=$idInfo->{TitleObj}->QualifierTypeID();

    if ( $self->{op}->{Dates} & OP_UPDATE ) {

	# don't add dates only fix them for tv_series
	if ( $qualifierID == IMDB::Local::QualifierType::MOVIE  ||
	     $qualifierID == IMDB::Local::QualifierType::TV_MOVIE ||
	     $qualifierID == IMDB::Local::QualifierType::VIDEO_MOVIE ) {
	    #$self->debug("adding 'date' field (\"$idInfo->{year}\") on \"$title\"");
	    my $date=int($idInfo->{year});

	    if ( defined($prog->{date}) ) {
		if ( $self->{op}->{Dates} & OP_REPLACE ) {
		    $self->debug("replacing 'date' field");
		    $prog->{date}=$date;
		}
		else {
		    $self->debug("preserving existing 'date' field");
		}
	    }
	    else {
		$self->debug("added 'date' field");
		$prog->{date}=$date;
	    }
	}
	else {
	    #$self->debug("not adding 'date' field to $qualifier \"$title\"");
	}
    }
    
    if ( $self->{op}->{Titles} & OP_UPDATE ) {
	if ( defined($prog->{title}) ) {
	    if ( $self->{op}->{Titles} & OP_REPLACE ) {
		$self->debug("replacing 'title' field");
		delete($prog->{title});

	    }
	    else {
		# MERGE title

		my $name=$idInfo->{title};
		my $found=0;
		for my $v (@{$prog->{title}}) {
		    if ( lc($v->[0]) eq lc($name) ) {
			$found=1;
		    }
		}
		if ( !$found ) {
		    $self->debug("added alternative 'title' field");

		    push(@{$prog->{title}}, [$idInfo->{title}, undef]);
		}
		else {
		    #$self->debug("added alternative 'title' field");
		}
	    }
	}
	else {
	    # this case is quite unlikely given how we got here
	    my @list;
	    push(@list, [$idInfo->{title}, undef]);
	    $prog->{title}=\@list;

	    $self->debug("added 'title' field");
	}
    }

    if ( $self->{op}->{URLs} & OP_UPDATE ) {
	my $newUrl=$idInfo->{TitleObj}->imdbUrl();
	if ( defined($prog->{url}) ) {
	    if ( $self->{op}->{URLs} & OP_REPLACE ) {
		$self->debug("replacing 'url' field");
		delete($prog->{url});
		push(@{$prog->{url}}, $newUrl);
	    }
	    else {
		my $found=0;
		for my $v (@{$prog->{url}}) {
		    # skip if matches or if this is a similar enough url
		    if ( lc($v) eq lc($newUrl) || $v=~m;imdb.com/M/title-exact;io ) {
			$found=1;
		    }
		}
		if ( !$found ) {
		    $self->debug("added alternative 'url' field");
		    push(@{$prog->{url}}, $newUrl);
		}
	    }
	}
	else {
	    $self->debug("added 'url' field");
	    push(@{$prog->{url}}, $newUrl);
	}
    }

    my $titleobj=$idInfo->{TitleObj};

    # add directors list
    if ( $self->{op}->{Directors} & OP_UPDATE ) {
	if ( !defined($titleobj->Directors) ) {
	    $titleobj->populateDirectors();
	}

	if ( $titleobj->Directors_count ) {
	    # only update directors if we have exactly one or if
	    # its a movie of some kind, add more than one.
	    my $doUpdate=0;
	    if ( $qualifierID == IMDB::Local::QualifierType::MOVIE  ||
		 $qualifierID == IMDB::Local::QualifierType::TV_MOVIE ||
		 $qualifierID == IMDB::Local::QualifierType::VIDEO_MOVIE ) {
		$doUpdate=1;
	    }
	    elsif ( $qualifierID == IMDB::Local::QualifierType::VIDEO_GAME ||
		    $qualifierID == IMDB::Local::QualifierType::TV_SERIES ||
		    $qualifierID == IMDB::Local::QualifierType::TV_MINI_SERIES ) {
		# TODO - historical, only add directors if there is 1 - should re-visit
		if ( $titleobj->Directors_count == 1 ) {
		    $doUpdate=1;
		}
		else {
		    $self->debug("not adding 'director' field to $qualifierID \"$title\"");
		}
	    }
	    else {
		die "unexpected qualifierID $qualifierID";
	    }

	    if ( $doUpdate ) {
		my @list;

		# add top 3 billing directors list form www.imdb.com
		for (my $c=0; $c<4 && $c>$titleobj->Directors_count ; $c++) {
		    #for my $name (splice(@{$details->{directors}},0,3)) {
		    push(@list, $titleobj->Directors_index($c)->FullName);
		}

		if ( defined($prog->{credits}->{director}) ) {
		    if ( $self->{op}->{Directors} & OP_REPLACE ) {
			$self->debug("replacing 'director' field");
			delete($prog->{credits}->{director});
			$prog->{credits}->{director}=\@list;
		    }
		    else {
			my $found=0;
			my @list2add;
			for my $name (@list) {
			    for my $v (@{$prog->{credits}->{director}}) {
				if ( lc($v) eq lc($name) ) {
				    $found=1;
				}
			    }
			    if ( !$found ) {
				push(@list2add, $name);
			    }
			}
			if ( @list2add ) {
			    $self->debug("added alternative 'director' field");
			    push(@{$prog->{credits}->{director}}, @list2add);
			}
		    }
		}
		else {
		    $self->debug("added 'director(s)' field");
		    push(@{$prog->{credits}->{director}}, @list);
		}
	    }
	}
    }


    if ( $self->{op}->{Actors} & OP_UPDATE ) {
	if ( !defined($titleobj->Actors) ) {
	    $titleobj->populateActors();
	}

	if ( $titleobj->Actors_count ) {
	    my @list;
	    
	    # add top billing actors (default = 3) from www.imdb.com
	    for (my $c=0; $c<$self->{numActors} && $c>$titleobj->Actors_count ; $c++) {
		#for my $name (splice(@{$details->{actors}},0,$self->{numActors})) {
		push(@list, $titleobj->Actors_index($c)->FullName);
	    }
	    
	    if ( defined($prog->{credits}->{actor}) ) {
		if ( $self->{op}->{Actors} & OP_REPLACE ) {
		    $self->debug("replacing 'actor' field");
		    delete($prog->{credits}->{actor});
		    $prog->{credits}->{actor}=\@list;
		}
		else {
		    my $found=0;
		    my @list2add;
		    for my $name (@list) {
			for my $v (@{$prog->{credits}->{actor}}) {
			    if ( lc($v) eq lc($name)) {
				$found=1;
			    }
			}
			if ( !$found ) {
			    push(@list2add, $name);
			}
		    }
		    if ( @list2add ) {
			$self->debug("added alternative 'actor' field");
			push(@{$prog->{credits}->{actor}}, @list2add);
		    }
		}
	    }
	    else {
		$self->debug("added 'actor(s)' field");
		push(@{$prog->{credits}->{actor}}, @list);
	    }
	}
    }

    if ( $self->{op}->{Presenters} & OP_UPDATE ) {
	if ( !defined($titleobj->Hosts) ) {
	    $titleobj->populateHosts();
	}

	if ( $titleobj->Hosts_count ) {
	    my @list;
	    
	    for ($titleobj->Hosts()) {
		push(@list, $_->FullName);
	    }
	    
	    if ( defined($prog->{credits}->{presenter}) ) {
		if ( $self->{op}->{Presenters} & OP_REPLACE ) {
		    $self->debug("replacing 'presenter' field");
		    delete($prog->{credits}->{presenter});
		    $prog->{credits}->{presenter}=\@list;
		}
		else {
		    my $found=0;
		    my @list2add;
		    for my $name (@list) {
			for my $v (@{$prog->{credits}->{presenter}}) {
			    if ( lc($v) eq lc($name)) {
				$found=1;
			    }
			}
			if ( !$found ) {
			    push(@list2add, $name);
			}
		    }
		    if ( @list2add ) {
			$self->debug("added alternative 'presenter' field");
			push(@{$prog->{credits}->{presenter}}, @list2add);
		    }
		}
	    }
	    else {
		$self->debug("added 'presenter' field");
		push(@{$prog->{credits}->{presenter}}, @list);
	    }
	}
    }

    if ( $self->{op}->{Commentators} & OP_UPDATE ) {
	if ( !defined($titleobj->Narrators_count) ) {
	    $titleobj->populateNarrators();
	}

	if ( $titleobj->Narrators_count ) {
	    my @list;
	    
	    for ($titleobj->Narrators()) {
		push(@list, $_->FullName);
	    }
	    
	    if ( defined($prog->{credits}->{commentator}) ) {
		if ( $self->{op}->{Commentators} & OP_REPLACE ) {
		    $self->debug("replacing 'commentator' field");
		    delete($prog->{credits}->{commentator});
		    $prog->{credits}->{commentator}=\@list;
		}
		else {
		    my $found=0;
		    my @list2add;
		    for my $name (@list) {
			for my $v (@{$prog->{credits}->{commentator}}) {
			    if ( lc($v) eq lc($name)) {
				$found=1;
			    }
			}
			if ( !$found ) {
			    push(@list2add, $name);
			}
		    }
		    if ( @list2add ) {
			$self->debug("added alternative 'commentator' field");
			push(@{$prog->{credits}->{commentator}}, @list2add);
		    }
		}
	    }
	    else {
		$self->debug("added 'commentator' field");
		push(@{$prog->{credits}->{commentator}}, @list);
	    }
	}
	else {
	    $self->debug("no commentators to add");
	}
    }

    # squirrel away movie qualifier so its first on the list of replacements
    if ( !defined($self->{categories}->{$qualifierID}) ) {
	die "how did we get here with an invalid qualifier '$qualifierID'";
    }

    if ( $self->{op}->{Categories} & OP_UPDATE ) {
	my @categories;
	push(@categories, [$self->{categories}->{$qualifierID}, 'en']);

	# push genres as categories
	if ( $self->{updateCategoriesWithGenres} ) {
	    if ( ! defined($titleobj->Genres_count)  ) {
		$titleobj->populateGenres;
	    }
	    if ( $titleobj->Genres_count ) {
		for (my $n=0; $n < $titleobj->Genres_count() ; $n++) {
		    push(@categories, [$titleobj->Genres_index($n)->Name, 'en']);
		}
	    }
	}

	if ( @categories ) {
	    if ( defined($prog->{category}) ) {
		if ( $self->{op}->{Categories} & OP_REPLACE ) {
		    $self->debug("replacing 'category' field");
		    delete($prog->{category});
		    $prog->{category}=\@categories;
		}
		else {
		    for my $value (@{$prog->{category}}) {
			my $found=0;
			#print "checking category $value->[0] with $mycategory\n";
			for my $c (@categories) {
			    if ( lc($c->[0]) eq lc($value->[0]) ) {
				$found=1;
			    }
			}
			if ( !$found ) {
			    push(@categories, $value);
			}
		    }
		    $prog->{category}=\@categories;
		}
	    }
	    else {
		$self->debug("added 'category' field");
		$prog->{category}=\@categories;
	    }
	}
	else {
	    $self->debug("no commentators to add");
	}
    }

    if ( $self->{op}->{StarRating} & OP_UPDATE ) {
	if ( !defined($titleobj->Rating) ) {
	    $titleobj->populateRating;
	}

	if ( defined($titleobj->Rating) ) {
	    if ( defined($prog->{'star-rating'}) ) {
		if ( $self->{op}->{StarRating} & OP_REPLACE ) {
		    $self->debug("replacing 'star-rating' field");
		    delete($prog->{'star-rating'});
		    # add IMDB User Rating in front of all other star-ratings
		    push(@{$prog->{'star-rating'}}, [ $titleobj->Rating->Rank."/10", 'IMDB User Rating' ] );
		}
		else {
		    # todo - need to check if it already exists
		    my $found=0;
		    my @keep;
		    for my $r (@{$prog->{'star-rating'}}) {
			if ( scalar(@$r) > 1 ) {
			    warn("check rating ". $r->[1]);
			    use Data::Dumper;
			    warn Dumper($r);
			    if ( lc($r->[1]) eq lc('IMDB User Rating') ) {
				if ( $r->[0] eq $titleobj->Rating->Rank."/10") {
				    $found=1;
				}
				# lets replace the imdb user rating that exists
			    }
			    else {
				push(@keep, $r);
			    }
			}
			else {
			    push(@keep, $r);
			}
		    }
		    if ( !$found ) {
			# add IMDB User Rating in front of all other star-ratings
			unshift( @keep, [ $titleobj->Rating->Rank. "/10", 'IMDB User Rating' ] );
			$prog->{'star-rating'}=\@keep;
		    }
		}
	    }
	    else {
		$self->debug("added 'star-rating' field");
		push(@{$prog->{'star-rating'}}, [ $titleobj->Rating->Rank."/10", 'IMDB User Rating' ] );
	    }
	}
	else {
	    $self->debug("no rating to add");
	}
    }
	
    if ( $self->{op}->{Keywords} & OP_UPDATE ) {
	if ( !defined($titleobj->Keywords_count) ) {
	    $titleobj->populateKeywords;
	}

	if ( $titleobj->Keywords_count ) {
	    my @keywords;
	    for (my $n=0; $n < $titleobj->Keywords_count() ; $n++) {
		push(@keywords, [$titleobj->Keywords_index($n), 'en']);
	    }
	    
	    if ( defined($prog->{keywords}) ) {
		if ( $self->{op}->{Keywords} & OP_REPLACE ) {
		    $self->debug("replacing 'keywords' field");
		    delete($prog->{keywords});
		    $prog->{keywords}=\@keywords
		}
		else {
		    for my $value (@{$prog->{keyword}}) {
			my $found=0;
			for my $k (@keywords) {
			    if ( lc($k->[0]) eq lc($value->[0]) ) {
				$found=1;
			    }
			}
			if ( !$found ) {
			    push(@keywords, $value);
			}
		    }
		    $prog->{keyword}=\@keywords;
		}
	    }
	    else {
		$prog->{keyword}=\@keywords;
	    }
	}
	else {
	    $self->debug("no keywords to add");
	}
    }

    if ( $self->{op}->{Description} & OP_UPDATE ) {
	if ( !defined($titleobj->Plots_count) ) {
	    $titleobj->populatePlots;
	}

	# plot is held as a <desc> entity
	# if 'replacePlot' then delete all existing <desc> entities and add new
	# else add this plot as an additional <desc> entity
	#
	if ( $titleobj->Plots_count ) {
	    
	    # lets just add the first one
	    my $plot=$titleobj->Plots_index(0)->Description;
	    
	    if ( defined($prog->{desc}) ) {
		if ( $self->{op}->{Description} & OP_REPLACE ) {
		    $self->debug("replacing 'desc' field");
		    delete($prog->{desc});
		    push(@{$prog->{desc}}, [ $plot, 'en' ]);
		}
		else {
		    my $found=0;
		    for my $value (@{$prog->{desc}}) {
			if ( lc($plot) eq lc($value->[0]) ) {
			    $found=1;
			}
		    }
		    if ( !$found ) {
			push(@{$prog->{desc}}, [ $plot, 'en' ]);
		    }
		}
	    }
	    else {
		push(@{$prog->{desc}}, [ $plot, 'en' ]);
	    }
	}
	else {
	    $self->debug("no plot to add");
	}
    }

    return($prog);
}

sub augmentProgram($$$)
{
    my ($self, $prog, $movies_only)=@_;

    $self->{stats}->{programCount}++;
    
    # assume first title in first language is the one we want.
    my $title=$prog->{title}->[0]->[0];

    if ( defined($prog->{date}) && $prog->{date}=~m/^\d\d\d\d$/o ) {
	
	# for programs with dates we try:
	# - exact matches on movies
	# - exact matches on tv series
	# - close matches on movies
	my $id=$self->findMovieInfo($title, $prog->{date}, 1); # exact match
	if ( !defined($id) ) {
	    $id=$self->findTVSeriesInfo($title);
	    if ( !defined($id) ) {
		$id=$self->findMovieInfo($title, $prog->{date}, 0); # close match
	    }
	}
	if ( defined($id) ) {

	    #if ( !defined($id->{TitleObj}->QualifierType()) ) {
	    #if ( ! $id->{TitleObj}->populateQualifierType() ) {
	    #die "unable to locate qualifiertype for ".$id->{TitleObj}->TitleID;
	    #}
	    #}
	    
	    my $qualifier=$id->{TitleObj}->QualifierTypeID();
    
	    $self->{stats}->{$id->{matchLevel}."Matches"}++;
	    $self->{stats}->{$id->{matchLevel}}->{$qualifier}++;
	    return($self->applyFound($prog, $id));
	}
	$self->status("failed to find a match for movie \"$title ($prog->{date})\"");
	return(undef);
	# fall through and try again as a tv series
    }

    if ( !$movies_only ) {
	my $id=$self->findTVSeriesInfo($title);
	if ( defined($id) ) {
	    #if ( !defined($id->{TitleObj}->QualifierType()) ) {
	    #if ( ! $id->{TitleObj}->populateQualifierType() ) {
	    #die "unable to locate qualifiertype for ".$id->{TitleObj}->TitleID;
	#}
	#}
	    
	    my $qualifier=$id->{TitleObj}->QualifierTypeID();
    
	    $self->{stats}->{$id->{matchLevel}."Matches"}++;
	    $self->{stats}->{$id->{matchLevel}}->{$qualifier}++;
	    return($self->applyFound($prog, $id));
	}

	$self->status("failed to find a match for show \"$title\"");
    }
    return(undef);
}

#
# todo - add in stats on other things added (urls ?, actors, directors,categories)
#        separate out from what was added or updated
#
sub getStatsLines($)
{
    my $self=shift;
    my $totalChannelsParsed=shift;

    my $endTime=time();
    my %stats=%{$self->{stats}};

    my $ret=sprintf("Checked %d programs, on %d channels\n", $stats{programCount}, $totalChannelsParsed);
    
    $ret.="  ".scalar(keys %{$self->{titleCache}})." unique programs examined\n";

    for my $cat (sort {$a<=>$b} keys %{$self->{categories}}) {
	$ret.=sprintf("  found %d %s titles",
		      $stats{perfect}->{$cat}+$stats{close}->{$cat},
		      $self->{categories}->{$cat});
	if ( $stats{close}->{$cat} != 0 ) {
	    if ( $stats{close}->{$cat} == 1 ) {
		$ret.=sprintf(" (%d was not perfect)", $stats{close}->{$cat});
	    }
	    else {
		$ret.=sprintf(" (%d were not perfect)", $stats{close}->{$cat});
	    }
	}
	$ret.="\n";
    }

    $ret.=sprintf("  augmented %.2f%% of the programs, parsing %.2f programs/sec\n",
		  ($stats{programCount}!=0)?(($stats{perfectMatches}+$stats{closeMatches})*100)/$stats{programCount}:0,
		  ($endTime!=$stats{startTime} && $stats{programCount} != 0)?
		  $stats{programCount}/($endTime-$stats{startTime}):0);
		 
    return($ret);
}

1;
