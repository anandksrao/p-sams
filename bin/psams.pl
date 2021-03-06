#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Std;
use Config::Tiny;
use DBI;
use FindBin qw($Bin);
use HTML::Entities qw(decode_entities encode_entities);
use File::Temp qw(tempfile);
use constant DEBUG => 0;
use Data::Dumper;

################################################################################
# Begin variables
################################################################################
#my (%opt, @accessions, $fasta, $species, $fb, $ids, $bg, @t_sites, $construct);
my (%opt, $accession_list, $fasta, $species, $fb, $construct, $unlimit);
getopts('a:s:t:f:c:hou',\%opt);
arg_check();

# Constants
our $conf_file = "$Bin/../psams.conf";
our $targetfinder = "$Bin/../TargetFinder/targetfinder.pl";
our $tmpdir = "$Bin/../tmp";
our $conf = Config::Tiny->read($conf_file);
our $seed = 15;
our $min_length = 9;
our $esc = '^\n\x20\x41-\x5a\x61-\x7a';
our ($mRNAdb, $db, $dbh, $db_host, $db_usr, $db_passwd);
if ($species) {
	$mRNAdb = $conf->{$species}->{'mRNA'};
	$db = $conf->{$species}->{'sql'};
	# Connect to the SQLite database
	$db_host = $conf->{'DATABASE'}->{'host'};
	$db_usr = $conf->{'DATABASE'}->{'user'};
	$db_passwd = $conf->{'DATABASE'}->{'password'};
	$dbh = DBI->connect("dbi:mysql:dbname=$db:host=$db_host", $db_usr, $db_passwd);
}
#our $execution_system = 'serial';
our $execution_system = 'pbs';

################################################################################
# End variables
################################################################################

################################################################################
# Begin main
################################################################################

if ($construct eq 'amiRNA') {
	# Get target sequences
	my $ids;
	my $bg = ($opt{'o'}) ? 1 : 0;
	if ($fasta) {
		$ids = build_fg_index_fasta($fasta);
	} else {
		my @accessions = parse_list(',', $accession_list);
		$ids = build_fg_index(@accessions);
	}

	# Run pipeline
	my ($opt_count, $subopt_count, $opt_r, $sub_r) = pipeline($ids, $seed, $bg, $fb, $construct);
	amirna_json($opt_count, $subopt_count, $opt_r, $sub_r);

} elsif ($construct eq 'syntasiRNA') {
	$construct = 'syn-tasiRNA';
	my $bg = ($opt{'o'}) ? 1 : 0;
	my (%groups, $count);
	if ($fasta) {
		my @fasta = split /;/, $fasta;
		$count = scalar(@fasta);
		for (my $g = 0; $g < $count; $g++) {
		#foreach my $group (@fasta) {
			#my $ids = build_fg_index_fasta($group);
			my $ids = build_fg_index_fasta($fasta[$g]);
			my ($opt_count, $subopt_count, $opt_r, $sub_r) = pipeline($ids, $seed, $bg, $fb, $construct);
			$groups{$g}->{'opt'} = $opt_count;
			$groups{$g}->{'sub'} = $subopt_count;
			$groups{$g}->{'opt_r'} = $opt_r;
			$groups{$g}->{'sub_r'} = $sub_r;
			#syntasirna_json($opt_count, $subopt_count, $opt_r, $sub_r);
		}
	} else {
		my @groups = split /;/, $accession_list;
		$count = scalar(@groups);
		for (my $g = 0; $g < $count; $g++) {
		#foreach my $group (@groups) {
			#my @accessions = parse_list(',', $group);
			my @accessions = parse_list(',', $groups[$g]);
			my $ids = build_fg_index(@accessions);
			my ($opt_count, $subopt_count, $opt_r, $sub_r) = pipeline($ids, $seed, $bg, $fb, $construct);
			$groups{$g}->{'opt'} = $opt_count;
			$groups{$g}->{'sub'} = $subopt_count;
			$groups{$g}->{'opt_r'} = $opt_r;
			$groups{$g}->{'sub_r'} = $sub_r;
			#syntasirna_json($opt_count, $subopt_count, $opt_r, $sub_r);
		}
	}
	syntasirna_json($count, \%groups);
} else {
	arg_error("Construct type $construct is not supported!");
}

exit;
################################################################################
# End main
################################################################################

################################################################################
# Begin functions
################################################################################

########################################
# Function: pipeline
# Wraps most of the functions into one
########################################
sub pipeline {
	my $ids = shift;
	my $seed = shift;
	my $bg = shift;
	my $fb = shift;
	my $construct = shift;
	
	my (%opt_results, %subopt_results);

	# Find sites
	my @t_sites = get_tsites($ids, $seed, $bg);

	# Group sites
	my @gsites = group_tsites($seed, @t_sites);

	# Scoring sites
	my $target_count = scalar(keys(%{$ids}));
	print STDERR "Expected target count = $target_count\n" if (DEBUG);
	@gsites = score_sites($target_count, $seed, $fb, @gsites);
	print STDERR Dumper(@gsites) if (DEBUG);

	my ($opt, $subopt);
	if ($execution_system eq 'serial' || $bg == 0) {
		($opt, $subopt) = serial_jobs($target_count, $construct, $ids, $bg, @gsites);
	} elsif ($execution_system eq 'pbs') {
		($opt, $subopt) = pbs_jobs($target_count, $construct, $ids, @gsites);
	}

	@{$subopt} = sort {$a->{'off_targets'} <=> $b->{'off_targets'}} @{$subopt};
	
	print STDERR Dumper($opt) if (DEBUG);
	
	my $result_count = 0;
	my $opt_count = 0;
	foreach my $site (@{$opt}) {
		$opt_count++;
		$result_count++;
		@{$site->{'tf'}}[1] =~ s/$construct\d+/$construct Optimal Result $result_count/;
		$opt_results{$opt_count}->{'guide'} = $site->{'guide'};
		$opt_results{$opt_count}->{'star'} = $site->{'star'};
		$opt_results{$opt_count}->{'oligo1'} = $site->{'oligo1'};
		$opt_results{$opt_count}->{'oligo2'} = $site->{'oligo2'};
		$opt_results{$opt_count}->{'tf'} = $site->{'tf'};
	}

	$result_count = 0;
	my $subopt_count = 0;
	foreach my $ssite (@{$subopt}) {
		$subopt_count++;
		$result_count++;
		my $site = \%{$ssite->{'site'}};

		@{$site->{'tf'}}[1] =~ s/$construct\d+/$construct Suboptimal Result $result_count/;
		$subopt_results{$subopt_count}->{'guide'} = $site->{'guide'};
		$subopt_results{$subopt_count}->{'star'} = $site->{'star'};
		$subopt_results{$subopt_count}->{'oligo1'} = $site->{'oligo1'};
		$subopt_results{$subopt_count}->{'oligo2'} = $site->{'oligo2'};
		$subopt_results{$subopt_count}->{'tf'} = $site->{'tf'};
		last if ($subopt_count == 3);
	}
	
	return ($opt_count, $subopt_count, \%opt_results, \%subopt_results);
}

########################################
# Function: build_fg_index_fasta
# Parses sequences in FASTA-format and builds the foreground index
########################################

sub build_fg_index_fasta {
	my $fasta = shift;
	my %ids;

	print STDERR "Building foreground index... " if (DEBUG);
	my @fasta = split /\n/, $fasta;
	my $id;
	for (my $i = 0; $i < scalar(@fasta); $i++) {
		next if ($fasta[$i] =~ /^\s*$/);
		if (substr($fasta[$i],0,1) eq '>') {
			$id = substr($fasta[$i],1);
			$ids{$id} = '';
			#$ids{$id}->{$id} = '';
		} else {
			$ids{$id} .= $fasta[$i];
			#$ids{$id}->{$id} .= $fasta[$i];
		}
	}
	print STDERR scalar(keys(%ids))." sequences loaded..." if (DEBUG);
	print STDERR "done\n" if (DEBUG);

	return \%ids;
}

########################################
# Function: build_fg_index
# Adds gene accessions to the foreground index
########################################
sub build_fg_index {
	my @accessions = @_;
	my %ids;

	print STDERR "Building foreground index... " if (DEBUG);
	my $sth = $dbh->prepare("SELECT * FROM `annotation` WHERE `transcript` LIKE ?");
	foreach my $accession (@accessions) {
		# If the user entered transcript IDs we need to convert to gene IDs
		# For most species remove the isoform number (dot + one or two digits)
		$accession =~ s/\.\d{1,2}$//;
		# For maize isoforms are named differently
		if ($species eq 'Z_MAYS') {
			# There is a set where the transcript is named FGT### and the gene is named FG###
			if (substr($accession, 0, 2) eq 'AC') {
				$accession =~ s/FGT/FG/;
			} else {
				# Most isoforms are named _T##
				$accession =~ s/_T\d{2}$//;	
			}
		} elsif ($species eq 'C_REINHARDTII') {
				$accession =~ s/\.t\d$//;
		}
		
		if (length($accession) < $min_length) {
			print "Gene $accession not found in database! Please make sure your gene IDs are correct.\n";
			exit 1;
		}
		

		# Get transcript names
		my $exists = 0;
		$sth->execute("$accession%");
		while (my $result = $sth->fetchrow_hashref) {
			$exists = 1;
			#$ids{$accession}->{$result->{'transcript'}} = '';
			$ids{$result->{'transcript'}} = '';
			open FASTA, "samtools faidx $mRNAdb $result->{'transcript'} |";
			while (my $line = <FASTA>) {
				next if (substr($line,0,1) eq '>');
				chomp $line;
				#$ids{$accession}->{$result->{'transcript'}} .= $line;
				$ids{$result->{'transcript'}} .= $line;
			}
			close FASTA;
		}
		if ($exists == 0) {
			print "Gene $accession not found in database! Please make sure your gene IDs are correct.\n";
			exit 1;
		}
	}
	print STDERR "done\n" if (DEBUG);

	return \%ids;
}

########################################
# Function: get_tsites
# Identify all putative target sites
########################################
sub get_tsites {
	my $ids = shift;
	my $seed = shift;
	my $bg = shift;

	my @t_sites;
	my $site_length = 21;
	my $offset = $site_length - $seed - 1;

	print STDERR "Finding sites in foreground transcripts... \n" if (DEBUG);
	my (%discard, %found, $sth);
	if ($bg) {
		$sth = $dbh->prepare("SELECT * FROM `kmers` WHERE `kmer` = ?");
	}
	while (my ($transcript, $seq) = each(%{$ids})) {
		my $length = length($seq);
		print STDERR "  Transcript $transcript is $length nt long\n" if (DEBUG);
		for (my $i = 0; $i <= $length - $site_length; $i++) {
			my $site = substr($seq,$i,$site_length);
			next if (length($site) < $site_length);
			my $kmer = substr($site,$offset,$seed);
			if ($bg) {
				my $is_bg = 0;
				if (exists($discard{$kmer})) {
					$is_bg = 1;
					next;
				} elsif (!exists($found{$kmer})) {
					$sth->execute($kmer);
					while (my $result = $sth->fetchrow_hashref) {
						my @accessions = split /,/, $result->{'transcripts'};
						foreach my $accession (@accessions) {
							if (!exists($ids->{$accession})) {
								$is_bg = 1;
								$discard{$kmer} = 1;
								last;
							}
						}
						$found{$kmer} = 1;
					}
					next if ($is_bg == 1);
				}
			}
			my %hash;
			$hash{'name'} = $transcript;
			$hash{'seq'} = $site;
			push @t_sites, \%hash;
		}
	}

	return @t_sites;
}

########################################
# Function: group_tsites
# Group target sites based on seed sequence
########################################
sub group_tsites {
	my $seed = shift;
	my @t_sites = @_;

	my $site_length = 21;
	my $offset = $site_length - $seed - 1;

	print STDERR "Grouping sites... " if (DEBUG);
	@t_sites = sort {substr($a->{'seq'},$offset,$seed) cmp substr($b->{'seq'},$offset,$seed) || $a->{'name'} cmp $b->{'name'}} @t_sites;

	my (@names, $lastSeq, @seqs, @gsites);
	my $score = 0;
	my $i = 0;
	foreach my $row (@t_sites) {
		if (scalar(@names) == 0) {
			$lastSeq = $row->{'seq'};
		}
		if (substr($lastSeq,$offset,$seed) eq substr($row->{'seq'},$offset,$seed)) {
			push @names, $row->{'name'};
			push @seqs, $row->{'seq'};
			#$score += $row->{'ideal'};
		} else {
			my %hash;
			$hash{'names'} = join(";",@names);
			$hash{'seqs'} = join(";", @seqs);
			#$hash{'score'} = $score;

			# Edit distances
			#if (scalar(@names) > 1) {
			#	my @distances = adist(@seqs);
			#	@distances = sort {$b <=> $a} @distances;
			#	$hash{'distance'} = $distances[0];
			#} else {
			#	$hash{'distance'} = 0;
			#}
			push @gsites, \%hash;

			@names = $row->{'name'};
			@seqs = $row->{'seq'};
			#$score = $row->{'ideal'};

			$lastSeq = $row->{'seq'};
			if ($i == scalar(@t_sites) - 1) {
				my %last;
				$last{'names'} = $row->{'name'};
				$last{'seqs'} = $row->{'seq'};
				#$last{'score'} = $row->{'ideal'};
				#$last{'distance'} = 0;
			}
		}
		$i++;
	}
	print STDERR "done\n" if (DEBUG);

	return @gsites;
}

########################################
# Function: score_sites
# Scores sites based on similarity
########################################
sub score_sites {
	my $min_site_count = shift;
	my $seed = shift;
	my $fb = shift;
	my @gsites = @_;
	my $site_length = 21;
	my $offset = $site_length - $seed - 1;
	my @scored;

	# Score sites on:
	#     Pos. 1
	#     Pos. 2
	#     Pos. 3
	#     Non-seed sites
	#     Pos. 21

	foreach my $site (@gsites) {
		my @sites = split /;/, $site->{'seqs'};

		next if (scalar(@sites) < $min_site_count);
		# Get the max edit distance for this target site group
		#if (scalar(@sites) > 1) {
		#	# All distances relative to sequence 1
		#	my @distances = adist(@sites);
		#	# Max edit distance
		#	@distances = sort {$b <=> $a} @distances;
		#	if ($distances[0] < 0) {
		#		$distances[0] = 0;
		#	}
		#	$site->{'distance'} = $distances[0];
		#} else {
		#	$site->{'distance'} = 0;
		#}


		# Score sites on position 21
		for (my $i = 20; $i <= 20; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			if ($nts{'A'} == scalar(@sites)) {
				# Best sites have an A to pair with the miRNA 5'U
				$site->{'p21'} = 1;
			} elsif ($nts{'G'} == scalar(@sites)) {
				# Next-best sites have a G to have a G:U bp with the miRNA 5'U
				$site->{'p21'} = 2;
			} elsif ($nts{'A'} + $nts{'G'} == scalar(@sites)) {
				# Sites with mixed A and G can both pair to the miRNA 5'U, but not equally well
				$site->{'p21'} = 3;
				# Adjust distance due to mismatch at pos 21 because we account for it here
				#$site->{'distance'}--;
			} elsif ($nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				# All other sites will not match the miRNA 5'U, but this might be okay if no other options are available
				$site->{'p21'} = 4;
			} else {
				# All other sites will not match the miRNA 5'U, but this might be okay if no other options are available
				$site->{'p21'} = 4;
				# Adjust distance due to mismatch at pos 21 because we account for it here
				#$site->{'distance'}-- if (scalar(@sites) > 1);
			}
		}

		# Score sites on position 1
		for (my $i = 0; $i <= 0; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# Pos 1 is intentionally mismatched so any base is allowed here
			# However, if G and T bases are present together then pairing is unavoidable due to G:U base-pairing
			if ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'p1'} = 1;
			} elsif ($nts{'G'} > 0 && $nts{'T'} > 0) {
				$site->{'p1'} = 2;
				# Adjust distance due to mismatch at pos 1 because we account for it here
				#$site->{'distance'}--;
			} else {
				$site->{'p1'} = 1;
				# Adjust distance due to mismatch at pos 1 because we account for it here
				#$site->{'distance'}--;
			}
		}

		# Score sites on position 2
		for (my $i = 1; $i <= 1; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# We want to pair this position, but it is not required for functionality
			if ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				# We can pair all of these sites
				$site->{'p2'} = 1;
			} elsif ($nts{'G'} > 0 && $nts{'A'} > 0 && $nts{'G'} + $nts{'A'} == scalar(@sites)) {
				# We can pair or G:U pair all of these sites
				$site->{'p2'} = 2;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			} else {
				# Some of these will be unpaired
				$site->{'p2'} = 3;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			}
		}

		# Score sites on position 3
		for (my $i = 2; $i <= 2; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			# The miRNA is fixed at position 19 (C) so ideally we will have a G at position 3 of the target site
			# However, mismatches can be tolerated here
			if ($nts{'G'} == scalar(@sites)) {
				$site->{'p3'} = 1;
			} elsif ($nts{'A'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'p3'} = 2;
			} else {
				$site->{'p3'} = 3;
				# Adjust distance due to mismatch at pos 2 because we account for it here
				#$site->{'distance'}--;
			}
		}

		# Score remaining sites
		$site->{'other_mm'} = 0;
		for (my $i = 3; $i < $offset; $i++) {
			my %nts = (
				'A' => 0,
				'G' => 0,
				'C' => 0,
				'T' => 0
			);
			foreach my $seq (@sites) {
				$nts{substr($seq,$i,1)}++;
			}
			unless ($nts{'A'} == scalar(@sites) || $nts{'G'} == scalar(@sites) || $nts{'C'} == scalar(@sites) || $nts{'T'} == scalar(@sites)) {
				$site->{'other_mm'}++;
			}
		}

		my $guide = design_guide_RNA($site);
		next if (length($guide) < $site_length);
		$site->{'guide'} = $guide;
		my ($star, $oligo1, $oligo2) = oligo_designer($site->{'guide'}, $fb);
		$site->{'star'} = $star;
		$site->{'oligo1'} = $oligo1;
		$site->{'oligo2'} = $oligo2;
		push @scored, $site;
	}

	print STDERR "Sorting and outputing results... \n" if (DEBUG);
	@scored = sort {
		$a->{'other_mm'} <=> $b->{'other_mm'}
			||
		$a->{'p21'} <=> $b->{'p21'}
			||
		$a->{'p3'} <=> $b->{'p3'}
			||
		$a->{'p2'} <=> $b->{'p2'}
			||
		$a->{'p1'} <=> $b->{'p1'}
	} @scored;
	print STDERR "Analyzing ".scalar(@scored)." total sites... \n" if (DEBUG);

	return @scored;
}

########################################
# Function: design_guide_RNA
# Designs the guide RNA based on the
# target site sequence(s)
########################################
sub design_guide_RNA {
	my $site = shift;
	my $guide;

	my %mm = (
		'A' => 'A',
		'C' => 'C',
		'G' => 'G',
		'T' => 'T',
		'AC' => 'A',
		'AG' => 'A',
		'AT' => 'C',
		'CG' => 'A',
		'CT' => 'C',
		'ACG' => 'A',
		'ACT' => 'C',
		'GT' => 'G',
		'AGT' => 'G',
		'CGT' => 'T',
		'ACGT' => 'A'
	);

	my %bp = (
		'A' => 'T',
		'C' => 'G',
		'G' => 'C',
		'T' => 'A',
		'AC' => 'T',
		'AG' => 'T',
		'AT' => 'T',
		'CG' => 'C',
		'CT' => 'G',
		'ACG' => 'T',
		'ACT' => 'G',
		'GT' => 'C',
		'AGT' => 'T',
		'CGT' => 'A',
		'ACGT' => 'T'
	);

	# Format of site data structure
	#$site->{'names'}
	#$site->{'seqs'}
	#$site->{'other_mm'}
	#$site->{'p3'}
	#$site->{'p2'}
	#$site->{'p1'}
	#$site->{'p21'}
	my @sites = split /;/, $site->{'seqs'};

	# Create guide RNA string
	for (my $i = 0; $i <= 20; $i++) {
		my %nts = (
			'A' => 0,
			'C' => 0,
			'G' => 0,
			'T' => 0
		);

		# Index nucleotides at position i
		foreach my $seq (@sites) {
			$nts{substr($seq,$i,1)}++;
		}

		# Create a unique nt diversity screen for choosing an appropriate base pair
		my $str;
		foreach my $nt ('A','C','G','T') {
			if ($nts{$nt} > 0) {
				$str .= $nt;
			}
		}

		if ($i == 0) {
			# Pos 1 is intentionally mismatched so any base is allowed here
			# However, if G and T bases are present together then pairing is unavoidable due to G:U base-pairing
			$guide .= $mm{$str};
		} elsif ($i == 2) {
			# Pos 3 is fixed as a C to pair the the 5'G of the miRNA*
			$guide .= 'C';
		} elsif ($i == 20) {
			# Pos 21, all guide RNAs have a 5'U
			$guide .= 'T';
		} else {
			# All other positions are base paired
			$guide .= $bp{$str};
		}
	}

	return reverse $guide;
}

########################################
# Function: Off-target check
#   Use TargetFinder to identify the
#   spectrum of predicted target RNAs
########################################
sub off_target_check {
	my $site = shift;
	#my $mRNAdb = shift;
	#my $name = shift;
	my @tf_results = @_;

	# Format of site data structure
	#$site->{'names'}
	#$site->{'seqs'}
	#$site->{'other_mm'}
	#$site->{'p3'}
	#$site->{'p2'}
	#$site->{'p1'}
	#$site->{'p21'}
	#$site->{'guide'}

	my $offCount = 0;
	my $onCount = 0;
	my @json;
	my $sth = $dbh->prepare("SELECT * FROM `annotation` WHERE `transcript` = ?");
	#open TF, "$targetfinder -s $site->{'guide'} -d $mRNAdb -q $name -p json |";
	#while (my $line = <TF>) {
	foreach my $line (@tf_results) {
		chomp $line;
		push @json, $line;
		if ($line =~ /Target accession/) {
			my ($tag, $transcript) = split /\:\s/, $line;
			$transcript =~ s/",*//g;

			$sth->execute($transcript);
			my $result = $sth->fetchrow_hashref;
			if ($result->{'description'}) {
				$result->{'description'} = decode_entities($result->{'description'});
				$result->{'description'} = encode_entities($result->{'description'});
				$result->{'description'} =~ s/;//g;
				push @json, '        "Target description": "'.$result->{'description'}.'",';
			} else {
				push @json, '        "Target description": "unknown",';
			}

			if ($site->{'names'} =~ /$transcript/) {
				$onCount++;
			} else {
				$offCount++;
			}
		}
	}
	#close TF;
	return ($offCount, $onCount, @json);
}

########################################
# Function: oligo_designer
# Generates cloning oligonucleotide sequences
########################################
sub oligo_designer {
	my $guide = shift;
	my $type = shift;

	my $rev = reverse $guide;
	$rev =~ tr/ACGTacgt/TGCAtgca/;

	my @temp = split //, $rev;
	my $c = $temp[10];
	my $g = $temp[2];
	my $n = $temp[20];

	$c =~ tr/[AGCT]/[CTAG]/;

	my ($star1, $oligo1, $oligo2, $realstar, $string, $bsa1, $bsa2);
	if ($type eq 'eudicot') {
		$star1 = substr($rev,0,10).$c.substr($rev,11,10);
		$oligo1 = $guide.'ATGATGATCACATTCGTTATCTATTTTTT'.$star1;
		$oligo2 = reverse $oligo1;
		$oligo2 =~ tr/ACTGacgt/TGACtgca/;
		$realstar = substr($star1,2,20);
		$realstar = $realstar.'CA';
		$string = 'AGTAGAGAAGAATCTGTA'.$oligo1.'CATTGGCTCTTCTTACT';
		$bsa1 = 'TGTA';
		$bsa2 = 'AATG';
	} elsif ($type eq 'monocot') {
		$star1 = substr($rev,0,10).$c.substr($rev,11,9).'C';
		$oligo1 = $guide.'ATGATGATCACATTCGTTATCTATTTTTT'.$star1;
		$oligo2 = reverse $oligo1;
		$oligo2 =~ tr/ATGCatgc/TACGtacg/;
		$realstar = substr($star1,2,20);
		$realstar = $realstar.'CA';
		$string = 'GGTATGGAACAATCCTTG'.$oligo1.'CATGGTTTGTTCTTACC';
		$bsa1 = 'CTTG';
		$bsa2 = 'CATG';
	} else {
		print STDERR " Foldback type $type not supported.\n\n";
		exit 1;
	}

	return ($realstar, $bsa1.$oligo1, $bsa2.$oligo2);
}

########################################
# Function: syntasi_oligo_designer
# Generates cloning oligonucleotide sequences
########################################
sub syntasi_oligo_designer {
	my @guides = @_;

	my $bsa1 = "ATTA";
  my $bsa2 = "GTTC";
	
	my (@stars, $string);
	
	foreach my $guide (@guides) {
		$string .= $guide;
	}
	
	my $oligo1 = $bsa1.$string;
	
	# Define syn-tasiRNA* sequences
	for (my $g = 0; $g < scalar(@guides); $g++) {
		my $offset = 2 + (21 * $g);
		my $star = substr($oligo1,$offset,21);
		$star = reverse($star);
		$star =~ tr/ATGC/TACG/;
		push @stars, $star;
	}

	my $oligo2 = reverse($string);
	$oligo2 =~ tr/ATGC/TACG/;
	$oligo2 = $bsa2.$oligo2;

	return (join(',', @stars), $oligo1, $oligo2);
}

########################################
# Function: parse_list
# Parses deliminated lists into an array
########################################
sub base_pair {
	my $target = shift;
	my $name = shift;
	my $transcript = shift;
	my $guide = shift;
	my $construct = shift;

	my $start = index($transcript,$target);
	if ($start == -1) {
		print STDERR "Warning: site $target not found in transcript $name!\n\n";
		return;
	}
	my $end = $start + length($target) - 1;

	my %bp;
	$bp{"AU"} = 0;
	$bp{"UA"} = 0;
	$bp{"GC"} = 0;
	$bp{"CG"} = 0;
	$bp{"GU"} = 0.5;
	$bp{"UG"} = 0.5;
	$bp{"AC"} = 1;
	$bp{"CA"} = 1;
	$bp{"AG"} = 1;
	$bp{"GA"} = 1;
	$bp{"UC"} = 1;
	$bp{"CU"} = 1;
	$bp{"A-"} = 1;
	$bp{"U-"} = 1;
	$bp{"G-"} = 1;
	$bp{"C-"} = 1;
	$bp{"-A"} = 1;
	$bp{"-U"} = 1;
	$bp{"-G"} = 1;
	$bp{"-C"} = 1;
	$bp{"AA"} = 1;
	$bp{"UU"} = 1;
	$bp{"CC"} = 1;
	$bp{"GG"} = 1;
	my $homology_string;
	my $cycle = 0;
	my $score = 0;
	my $mismatch = 0;
	my $gu = 0;

	$target =~ s/T/U/g;
	$guide =~ s/T/U/g;
	$guide = reverse $guide;

	my @guide_nts = split //, $guide;
	my @target_nts = split //, $target;
	for (my $i = 1; $i <= length($guide); $i++) {
		$cycle++;
		my $guide_base = pop @guide_nts;
		my $target_base = pop @target_nts;
		if ($cycle == 1) {
			my $position = $bp{"$guide_base$target_base"};
			if ($position == 1) {
				$mismatch++;
				$homology_string .= ' ';
			} elsif ($position == 0.5) {
				$gu++;
				$homology_string .= '.';
			} else {
				$homology_string .= ':';
			}
			$score = $position;
		} elsif ($cycle > 13) {
			my $position = $bp{"$guide_base$target_base"};
			if ($position == 1) {
				$mismatch++;
				$homology_string .= ' ';
			} elsif ($position == 0.5) {
				$gu++;
				$homology_string .= '.';
			} else {
				$homology_string .= ':';
			}
			$score += $position;
		} else {
			my $position = ($bp{"$guide_base$target_base"}*2);
			if ($position == 2) {
				$mismatch++;
				$homology_string .= ' ';
			} elsif ($position == 1) {
				$gu++;
				$homology_string .= '.';
			} else {
				$homology_string .= ':';
			}
			$score += $position;
		}
	}

	$homology_string = reverse $homology_string;
	$homology_string =~ s/ /\&nbsp/g;

	my @hit;
	push @hit, '      {';
	push @hit, '        "Target accession": "'.$name.'",';
	push @hit, '        "Target description": "unknown",';
	push @hit, '        "Score": "'.$score.'",';
	push @hit, '        "Coordinates": "'.$start.'-'.$end.'",';
	push @hit, '        "Strand": "+",';
	push @hit, '        "Target sequence": "'.$target.'",';
	push @hit, '        "Base pairing": "'.$homology_string.'",';
	push @hit, '        "'.$construct.' sequence": "'.$guide.'"';
	push @hit, '      }';

	return @hit;
}

########################################
# Function: amirna_json
# Builds the JSON output for amiRNA results
########################################
sub amirna_json {
	my $opt_count = shift;
	my $sub_count = shift;
	my $opt = shift;
	my $sub = shift;
	
	my $result_count = 0;
	print "{\n";
	print '  "optimal": {'."\n";
	
	my @json;
	for (my $i = 1; $i <= $opt_count; $i++) {
		$result_count++;
		my $json = '    "amiRNA Optimal Result '.$result_count.'": {'."\n";
		$json .=   '      "amiRNA": "'.$opt->{$i}->{'guide'}.'",'."\n";
		$json .=   '      "amiRNA*": "'.$opt->{$i}->{'star'}.'",'."\n";
		$json .=   '      "Forward Oligo": "'.$opt->{$i}->{'oligo1'}.'",'."\n";
		$json .=   '      "Reverse Oligo": "'.$opt->{$i}->{'oligo2'}.'",'."\n";
		$json .=   '      "TargetFinder": '.join("\n      ", @{$opt->{$i}->{'tf'}})."\n";
		$json .=   '    }';
		push @json, $json;
	}
	print join(",\n", @json)."\n";
	print '  },'."\n";
	print '  "suboptimal": {'."\n";
	@json = ();
	$result_count = 0;
	for (my $i = 1; $i <= $sub_count; $i++) {
		$result_count++;
		my $json = '    "amiRNA Suboptimal Result '.$result_count.'": {'."\n";
		$json .=   '      "amiRNA": "'.$sub->{$i}->{'guide'}.'",'."\n";
		$json .=   '      "amiRNA*": "'.$sub->{$i}->{'star'}.'",'."\n";
		$json .=   '      "Forward Oligo": "'.$sub->{$i}->{'oligo1'}.'",'."\n";
		$json .=   '      "Reverse Oligo": "'.$sub->{$i}->{'oligo2'}.'",'."\n";
		$json .=   '      "TargetFinder": '.join("\n      ", @{$sub->{$i}->{'tf'}})."\n";
		$json .=   '    }';
		push @json, $json;
	}
	print join(",\n", @json)."\n";
	print '  }'."\n";
	print "}\n";
}

########################################
# Function: syntasirna_json
# Builds the JSON output for syntasiRNA results
########################################
sub syntasirna_json {
	my $group_count = shift;
	my $groups = shift;
	
	#$groups{$g}->{'opt'} = $opt_count;
	#$groups{$g}->{'sub'} = $subopt_count;
	#$groups{$g}->{'opt_r'} = $opt_r;
	#$groups{$g}->{'sub_r'} = $sub_r;
	
	my (%opt, %sub);
	print '{'."\n";
	print '  "blocks": ['."\n";
	
	my $set = 1;
	for (my $g = 0; $g < $group_count; $g++) {
		print '    {'."\n";
		print '      "name": "Gene set '.$set.'",'."\n";
		print '      "optimal": {'."\n";
		
		for (my $o = 1; $o <= $groups->{$g}->{'opt'}; $o++) {
			print '        "optimal '.$set.'.'.$o.'": {'."\n";
			print '          "syn-tasiRNA": "'.$groups->{$g}->{'opt_r'}->{$o}->{'guide'}.'",'."\n";
			print '          "TargetFinder": {'."\n";
			shift(@{$groups->{$g}->{'opt_r'}->{$o}->{'tf'}});
			shift(@{$groups->{$g}->{'opt_r'}->{$o}->{'tf'}});
			pop(@{$groups->{$g}->{'opt_r'}->{$o}->{'tf'}});
			pop(@{$groups->{$g}->{'opt_r'}->{$o}->{'tf'}});
			my $tf_obj = '        '.join("\n        ", @{$groups->{$g}->{'opt_r'}->{$o}->{'tf'}})."\n";
			$tf_obj =~ s/amiRNA/syn-tasiRNA/g;
			print $tf_obj;
			print '          }'."\n";
			if ($o < $groups->{$g}->{'opt'}) {
				print '        },'."\n";
			} else {
				print '        }'."\n";
			}
		}
		
		print '      },'."\n";
		print '      "suboptimal": {'."\n";
		
		for (my $s = 1; $s <= $groups->{$g}->{'sub'}; $s++) {
			print '        "suboptimal '.$set.'.'.$s.'": {'."\n";
			print '          "syn-tasiRNA": "'.$groups->{$g}->{'sub_r'}->{$s}->{'guide'}.'",'."\n";
			print '          "TargetFinder": {'."\n";
			shift(@{$groups->{$g}->{'sub_r'}->{$s}->{'tf'}});
			shift(@{$groups->{$g}->{'sub_r'}->{$s}->{'tf'}});
			pop(@{$groups->{$g}->{'sub_r'}->{$s}->{'tf'}});
			pop(@{$groups->{$g}->{'sub_r'}->{$s}->{'tf'}});
			my $tf_obj = '        '.join("\n        ", @{$groups->{$g}->{'sub_r'}->{$s}->{'tf'}})."\n";
			$tf_obj =~ s/amiRNA/syn-tasiRNA/g;
			print $tf_obj;
			print '          }'."\n";
			if ($s < $groups->{$g}->{'sub'}) {
				print '        },'."\n";
			} else {
				print '        }'."\n";
			}
		}
		
		print '      }'."\n";
		if ($g < $group_count - 1) {
			print '    },'."\n";
		} else {
			print '    }'."\n";
		}
		$set++;
	}
	
	print '  ]'."\n";
	print '}'."\n";
}

########################################
# Function: serial_jobs
# Submits jobs in serial on local system
########################################
sub serial_jobs {
	my $target_count = shift;
	my $construct = shift;
	my $ids = shift;
	my $bg = shift;
	my @gsites = @_;

	my $result_count = 0;
	my (@opt, @subopt);
	foreach my $site (@gsites) {
		$site->{'name'} = "$construct$result_count";

		if ($bg) {
			# TargetFinder
			my @tf_results;
			open TF, "$targetfinder -s $site->{'guide'} -d $mRNAdb -q $site->{'name'} -p json |";
			@tf_results = <TF>;
			close TF;
			my ($off_targets, $on_targets, @json) = off_target_check($site, @tf_results);

			if ($fasta) {
				# Add missing FASTA targets
				my @insert;
				my @seqs = split /;/, $site->{'seqs'};
				my @names = split /;/, $site->{'names'};
				for (my $i = 0; $i < scalar(@seqs); $i++) {
					my @hit = base_pair($seqs[$i], $names[$i], $ids->{$names[$i]}, $site->{'guide'}, $construct);
					push @insert, join("\n      ", @hit);
				}
				if ($off_targets == 0) {
					@json = ();
					push @json, '{';
					push @json, '  "'.$construct.$result_count.'": {';
					push @json, '    "hits": [';
					push @json, join(",\n", @insert);
					push @json, '    ]';
					push @json, '  }';
					push @json, '}';
					$site->{'tf'} = \@json;
					push @opt, $site;
					$result_count++;
				} else {
					my @new_json;
					for (my $i = 0; $i <= 2; $i++) {
						push @new_json, $json[$i];
					}
					push @new_json, join(",\n", @insert).',';
					for (my $i = 3; $i < scalar(@json); $i++) {
						push @new_json, $json[$i];
					}
					$site->{'tf'} = \@new_json;
					my %hash;
					$hash{'off_targets'} = $off_targets;
					$hash{'site'} = $site;
					push @subopt, \%hash;
				}
			} else {
				$site->{'tf'} = \@json;
				if ($off_targets == 0 && $on_targets == $target_count) {
					push @opt, $site;
					$result_count++;
				} else {
					my %hash;
					$hash{'off_targets'} = $off_targets;
					$hash{'site'} = $site;
					push @subopt, \%hash;
				}
			}
		} else {
			my @insert;
			my @seqs = split /;/, $site->{'seqs'};
			my @names = split /;/, $site->{'names'};
			for (my $i = 0; $i < scalar(@seqs); $i++) {
				my @hit = base_pair($seqs[$i], $names[$i], $ids->{$names[$i]}, $site->{'guide'}, $construct);
				push @insert, join("\n      ", @hit);
			}
			my @json;
			push @json, '{';
			push @json, '  "'.$site->{'name'}.'": {';
			push @json, '    "hits": [';
			push @json, join(",\n      ", @insert);
			push @json, '    ]';
			push @json, '  }';
			push @json, '}';
			$site->{'tf'} = \@json;
			push @opt, $site;
			$result_count++;
		}
		last if ($result_count == 3 && $unlimit == 0);
	}

	return (\@opt, \@subopt);
}

########################################
# Function: pbs_jobs
# Submits jobs in parallel to a Portable Batch System
########################################
sub pbs_jobs {
	my $target_count = shift;
	my $construct = shift;
	my $ids = shift;
	my @gsites = @_;

	my $template = 'tf_XXXXXX';

	my $n_jobs = scalar(@gsites);
	my $batch_size = 48;
	my $batches = int($n_jobs / $batch_size) + 1;
	my $job = 0;
	my $result_count = 0;
	my (@opt, @subopt);

	for (my $batch = 1; $batch <= $batches; $batch++) {
		print STDERR "Batch $batch, queuing jobs... " if DEBUG;
		my $end = $job + $batch_size - 1;
		if ($end >= $n_jobs) {
			$end = $n_jobs - 1;
		}

		# Submit TargetFinder jobs to queue
		my %jobs;
		for (my $j = $job; $j <= $end; $j++) {
			my $site = $gsites[$j];
			$site->{'name'} = "$construct$j";

			# Open temporary shell script to define job
			my ($fh, $filename) = tempfile($template, SUFFIX => '.sh', DIR => $tmpdir);
			print $fh '#!/bin/bash'."\n";
			print $fh "$targetfinder -s $site->{'guide'} -d $mRNAdb -q $site->{'name'} -p json\n";
			close $fh;
			$jobs{$j}->{'file'} = $filename;

			# Submit job to queue
			for (my $try = 1; $try <= 3; $try++) {
				open QSUB, "qsub -o $tmpdir -e $tmpdir $filename |";
				my $job_id = <QSUB>;
				close QSUB;
				if ($job_id) {
					chomp $job_id;
					my @tmp = split /\./, $job_id;
					my $job_number = $tmp[0];
					$jobs{$j}->{'job_id'} = $job_id;
					$jobs{$j}->{'status'} = 'queued';
					$jobs{$j}->{'jid'} = $job_number;
					last;
				} else {
					$jobs{$j}->{'status'} = 'failed';
				}
			}
		}
		print STDERR "done\n" if DEBUG;

		my $remaining = scalar(keys(%jobs));
		print STDERR "Waiting for jobs to finish... $remaining\r" if DEBUG;
		while ($remaining > 0) {
			for (my $j = $job; $j <= $end; $j++) {
				if ($jobs{$j}->{'status'} eq 'queued') {
					my @tmp = split /\./, $jobs{$j}->{'job_id'};
					my $job_number = $tmp[0];
					open QSTAT, "qstat -f $jobs{$j}->{'job_id'} 2> /dev/null |";
					my $status = <QSTAT>;
					close QSTAT;
					# Job is finished
					if (!$status && -e "$jobs{$j}->{'file'}.o$jobs{$j}->{'jid'}") {
						$jobs{$j}->{'status'} = 'finished';
						$remaining--;
						open (TF, "$jobs{$j}->{'file'}.o$jobs{$j}->{'jid'}") or warn " Cannot open file $jobs{$j}->{'file'}.o$jobs{$j}->{'jid'}: $!\n";
						my @tf_results = <TF>;
						close TF;

						# Off-targets
						if (@tf_results) {
							# Skip empty results
							next if ($tf_results[0] =~ /No results/ && !$fasta);
							my $site = $gsites[$j];
							my ($off_targets, $on_targets, @json) = off_target_check($site, @tf_results);

							if ($fasta) {
								# Add missing FASTA targets
								my @insert;
								my @seqs = split /;/, $site->{'seqs'};
								my @names = split /;/, $site->{'names'};
								for (my $i = 0; $i < scalar(@seqs); $i++) {
									my @hit = base_pair($seqs[$i], $names[$i], $ids->{$names[$i]}, $site->{'guide'}, $construct);
									push @insert, join("\n      ", @hit);
								}
								if ($off_targets == 0) {
									@json = ();
									push @json, '{';
									push @json, '  "'.$construct.$result_count.'": {';
									push @json, '    "hits": [';
									push @json, join(",\n", @insert);
									push @json, '    ]';
									push @json, '  }';
									push @json, '}';
									$site->{'tf'} = \@json;
									push @opt, $site;
									$result_count++;
								} else {
									my @new_json;
									for (my $i = 0; $i <= 2; $i++) {
										push @new_json, $json[$i];
									}
									push @new_json, join(",\n", @insert).',';
									for (my $i = 3; $i < scalar(@json); $i++) {
										push @new_json, $json[$i];
									}
									$site->{'tf'} = \@new_json;
									my %hash;
									$hash{'off_targets'} = $off_targets;
									$hash{'site'} = $site;
									push @subopt, \%hash;
								}
							} else {
								$site->{'tf'} = \@json;
								if ($off_targets == 0 && $on_targets == $target_count) {
									push @opt, $site;
									$result_count++;
								} else {
									my %hash;
									$hash{'off_targets'} = $off_targets;
									$hash{'site'} = $site;
									push @subopt, \%hash;
								}
							}
						}
					}
				} elsif ($jobs{$j}->{'status'} eq 'failed') {
					$jobs{$j}->{'status'} = 'finished';
					$remaining--;
				}
			}
			last if ($result_count == 3 && $unlimit == 0);
			print STDERR "Waiting for jobs to finish... $remaining\r" if DEBUG;
		}
		print STDERR "Waiting for jobs to finish... done\n" if DEBUG;

		# Cleanup
		print STDERR "Cleaning up... " if DEBUG;
		for (my $j = $job; $j <= $end; $j++) {
			# Dequeue remaining jobs
			`qdel $jobs{$j}->{'job_id'} 2> /dev/null`;
			# Remove files
			#unlink($jobs{$j}->{'file'},"$jobs{$j}->{'file'}.o$jobs{$j}->{'jid'}","$jobs{$j}->{'file'}.e$jobs{$j}->{'jid'}");
		}
		for (my $j = $job; $j <= $end; $j++) {
			# Remove files
			unlink($jobs{$j}->{'file'},"$jobs{$j}->{'file'}.o$jobs{$j}->{'jid'}","$jobs{$j}->{'file'}.e$jobs{$j}->{'jid'}");
		}
		$job = $end + 1;
		print STDERR "done\n" if DEBUG;
		last if ($result_count == 3 && $unlimit == 0);
	}

	return (\@opt, \@subopt);
}

########################################
# Function: parse_list
# Parses deliminated lists into an array
########################################
sub parse_list {
	my $sep = shift;
  my ($flatList) = @_;
  my @final_list;

  # put each deliminated entry in an array
  if ($flatList =~ /$sep/) {
    @final_list = split (/$sep/,$flatList);
  } else {
    push(@final_list,$flatList);
  }
 return @final_list;
}

########################################
# Function: arg_check
# Parse Getopt variables
########################################
sub arg_check {
	if ($opt{'h'}) {
		arg_error();
	}
	if (!$opt{'a'} && !$opt{'f'}) {
		arg_error('An input sequence or a gene accession ID were not provided!');
	}
	if ($opt{'a'}) {
		$accession_list = $opt{'a'};
		#@accessions = parse_list(',', $opt{'a'});
		if ($opt{'s'}) {
			$species = $opt{'s'};
		} else {
			arg_error('A species name was not provided!');
		}
	}
	if ($opt{'f'}) {
		$fasta = $opt{'f'};
		if ($opt{'s'}) {
			$species = $opt{'s'};
		}
	}
	if ($opt{'t'}) {
		$fb = $opt{'t'};
	} else {
		$fb = 'eudicot';
	}
	if ($opt{'c'}) {
		$construct = $opt{'c'};
	} else {
		$construct = 'amiRNA';
	}
	if ($opt{'u'}) {
		$unlimit = 1;
	} else {
		$unlimit = 0;
	}
}

########################################
# Funtion: arg_error
# Process input errors and print help
########################################
sub arg_error {
  my $error = shift;
  if ($error) {
    print STDERR $error."\n";
  }
  my $usage = "
usage: psams.pl [-f FASTA] [-a ACCESSIONS -s SPECIES] [-t FOLDBACK] [-c CONSTRUCT] [-o] [-h]

Plant Small RNA Maker Suite (P-SAMS).
  Artificial microRNA and synthetic trans-acting siRNA designer tool.

arguments:
  -t FOLDBACK           Foldback type [eudicot, monocot]. Default = eudicot.
  -f FASTA              FASTA-formatted sequence. Not used if -a is set.
  -a ACCESSION          Gene accession(s). Comma-separated list. Not used if -f is set.
  -s SPECIES            Species. Required if -a is set.
  -c CONSTRUCT          Construct type (amiRNA, syntasiRNA). Default = amiRNA.
  -o                    Predict off-target transcripts? Filters guide sequences to minimize/eliminate off-targets.
	-u                    Unlimited results (slow).
  -h                    Show this help message and exit.

  ";
  print STDERR $usage;
  exit 1;
}

################################################################################
# End functions
################################################################################
