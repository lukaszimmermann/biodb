#! /usr/bin/perl -w

#########################################################################################
#	Download all Genome Distribution files from NCBI
#	Updated Version July 2016
#
#	Author: Jörn Marialke, MPI for Evolutionary Biology, Tuebingen 2011 (version 0.1)
#   Author: Lukas Zimmermann (version 0.2)
#########################################################################################
### Folder Structure ####################################################################
#
#							<basedir = Timestamp>
#    _______________________________|_______________________________
#	|				|				|				|				|
# <logdir>		<distDir>		<dataDir>		<taxDir> 		<webDir>
# store logs		|							store tax *		store www stuff
#				____|____						
#			   |		 |	   		
#			<ensembl>  <ncbi> 
#  						 |
#						 |- Fungi +
#						 |- Eucaryota
#						 |- Bacteria  * 
#
#  * simple,single File Download
#  + traverse through NCBI Fungi folder and create for each org Folder + download .faa
#
#########################################################################################
use strict;
use warnings;
use Net::FTP;	
use Data::Dumper;
use Getopt::Long;
use File::Path;
use List::Util;



# Things one could do more intelligently
my @databaseNames = ('refseq', 'genbank');


# Suffixes of files to download. TODO Get this from the blocks file
my @filesToDownload = ('_protein.faa.gz', '_genomic.fna.gz');

#########################################################
# Some constants
my $a_s_delim = '\t';

# The name of the file where the filtered organism names are stored
my $organismFileName = "organism.dat";
my $baseDir;
my ($index_of, $allowed_values);

# Change these variables in case of changes to the server URL
# Global Variable declaration
# NCBI Sources
my $ncbi                = "ftp.ncbi.nih.gov";
my $srcNCBIBacDir       = "/genomes/refseq/bacteria/";
my $srcNCBIEukDir       = "/genomes/";
my $srcNCBIFunDir       = "/genomes/refseq/fungi/";
my $srcNCBIFluDir  	= "/genomes/INFLUENZA/";
my $sleeptime           = 900;

 
# ENSEMBL SOURCES
my $ensembl             = "ftp.ensembl.org";
my $srcEnsemblEukDir    = "/pub/current_fasta";


my $rootDir; 
my $v = 1;

# Processing command line options
if (@ARGV < 1) {
    die "ERROR   Please specify either 'ncbi' or 'ensembl'\n";
}


# Will hold the connection to the FTP 
my $ftp;


# START PROGRAM for subroutine NCBI

if($ARGV[0] eq "ncbi") {

if(@ARGV < 2) {

    die "ERROR   Please specify either 'list' or 'fetch'\n";
}


# Start program for subroutine "list"
if ($ARGV[1] eq "list") {

    if(@ARGV < 3) {

        die "ERROR   Please specify one of {headers, refseq, genbank}\n"
    }
    if($ARGV[2] eq "headers") {
	
        $ftp  = Net::FTP->new($ncbi, Debug => 0)
          or die "Cannot connect to $ncbi: $@";
        $ftp->login("anonymous",'-anonymous@');

        ($index_of, $allowed_values) = getAssemblyHeaders(); 
        
         while (my ($key, $value) = each %$allowed_values) {
          
            my @value_deref = @$value;
            if(scalar @value_deref == 0) {

                print "$key=*\n"; 
            } else {

                print "$key=",  join(",",@value_deref), "\n"; 
            }
          }
    } else {

	print "Currently not supported\n";
    }
   exit;


#  Start program for subroutine "fetch"
} elsif($ARGV[1] eq "fetch") {


my $d = '';
my $taxonomy = '';
my $f = '';
my $onlyList = '';
GetOptions('d=s' => \$d,
           '--only-list' => \$onlyList,
           'taxonomy' => \$taxonomy,
           'f=s' => \$f );
if(not $f) {
   die "ERROR  Please specify the description file with '-f'";
}
if(! -f $f) {
    die "ERROR   The file specified with '-f' does not exist";
}

if(not $d) {
   die("ERROR  please specify target directory with '-d'\n");
}
$rootDir = $d . '/';

# Die immediately if the Root Directory does not exist
if(! -d $rootDir) {
die "ROOT DIR ".$rootDir.": No such directory
The ROOT DIR must exist before this script can be executed.\n"
}


print "ROOT DIR  ".$rootDir."\n";
my @errors;


# Folder Structure Params 
# $dataDir contains all formatted genomes
my $timestamp = getTimestamp();
my $baseDirRel = $timestamp."/";
$baseDir = $rootDir.$baseDirRel;

my $distDir = $baseDir."distfiles/";
my $ncbiDir =  $distDir."ncbi/";
my $ncbiEukDir = $ncbiDir."Eukaryota/";
my $ncbiFunDir =  $ncbiDir."Fungi/";
my $ensemblDir = $distDir."ensembl/";

# Setting up Logfile Parameters

my $logfile      = $baseDir."log/".$timestamp.".log";
my $wget_log     = $baseDir."log/".$timestamp."_wget.log";
my $formatdb_log = $baseDir."log/".$timestamp."_formatdb.log";

# sources for the Influenza files
#my @influenzaFiles = ( "ftp://".$ncbi."".$srcNCBIFluDir."influenza.faa.gz",
#                       "ftp://".$ncbi."".$srcNCBIFluDir."influenza.fna.gz" );


#########################################################################################
# Parse the target file (-f) to determine which genome files to download
#########################################################################################
my @blocks;
my $databaseName = 'init';
my $domainName;
my $inBlock = 0;
my $filterString;
my $extractTo = '';
open(FILE1, $f);

while(<FILE1>) {
	
    # Chop away comments
    $_ = (split '#', $_)[0];

    # Block has ended
    if($_ =~ /^\s*$/) {
        if(not $inBlock) {
           next;
    }
    $inBlock = 0;
	if(not $databaseName) {
            die "ERROR  Database name is missing in block entry of target file. Terminating.\n";

    } elsif(not $domainName) {
	    die "ERROR   Domain is missing from block entry in target file. Terminating\n";
    }
    substr($filterString, 0, 1) = "";

    if(not $extractTo) {

        $extractTo = "/$databaseName/$domainName";
    }

    push @blocks, {databaseName => $databaseName, 
                   domainName => $domainName, 
                   extractTo => $extractTo,
                   selector => parseSelectorString($filterString)};

	$databaseName = '';
    $domainName = '';
    $filterString = '';
    $extractTo = '';

      # Database specifier encountered
    } elsif($_ =~ /\s*DATABASE\s*=\s*([^\s]+)\s+/) {
        $inBlock = 1;
	    $databaseName = checkDatabase($1);

      # Domain specifier encountered
    } elsif($_ =~ /\s*DOMAIN\s*=\s*([^\s]+)\s+/) {
        $inBlock = 1;
        $domainName = $1;

      # Extract_To Line encountered
    } elsif($_ =~ /\s*EXTRACT_TO\s*=\s*([^\s]+)\s+/) {      

       $extractTo = $1;

      # Filter string line encountered
    } elsif($_ =~ /\s*([A-Za-z_]+)\s*=\s*([A-Za-z_][A-Za-z_ ,]*[A-Za-z_])\s*/) {

         $filterString .= ":$1=$2";
     } else {

         die "ERROR  Strange line detected in target file: $_";
     }
}
if($inBlock) {

    if(not $databaseName) {
            die "ERROR  Database name is missing in block entry of target file. Terminating.\n";

    } elsif(not $domainName) {
	    die "ERROR   Domain is missing from block entry in target file. Terminating\n";
    }
    substr($filterString, 0, 1) = "";

    if(not $extractTo) {

        $extractTo = "/$databaseName/$domainName";
    }

    push @blocks, {databaseName => $databaseName, 
                   domainName   => $domainName,
                   extractTo => $extractTo,
                   selector => parseSelectorString($filterString)};
}
close(FILE1);



#########################################################################################
# Create the new Directory structure for the downloaded genomes 
# This will be the same as in the old download script, we want to keep the .Jar file 
# still working
#########################################################################################
if(! $taxonomy && scalar @blocks == 0) {

    print "You do not want to download taxonomy files and there were no blocks in the target file ... terminating.\n";
    exit;
} else {

    # We can now establish a connection to NCBI, as we either want to download taxonomy files
    # or we want to download genome block files
    $ftp  = Net::FTP->new($ncbi, Debug => 0)
        or die "Cannot connect to $ncbi: $@";
    $ftp->login("anonymous",'-anonymous@');

    # Also the Assembly Header lines are now required
    ($index_of, $allowed_values) = getAssemblyHeaders();


    # Check the validity of all blocks
    
       
    mkdir($baseDir, 0755);
    mkdir("$baseDir/log", 0755);
}

my $link_name = "current";
# Create Symlink
if(!(-e $rootDir.$link_name)){
    symlink($baseDirRel,$rootDir.$link_name);
} else{
    unlink($rootDir.$link_name);
    symlink($baseDirRel,$rootDir.$link_name);
}	



#########################################################################################
# Download the needed Taxonomy Data into the previously specified 'taxonomy' directory
# For this, the user must have specified the '--taxonomy' switch
#########################################################################################
if($taxonomy) { 
    mkdir("$baseDir/taxonomy", 0755);
    my @taxFiles = ("ftp://".$ncbi."/pub/taxonomy/taxdump.tar.gz",
                    "ftp://".$ncbi."/pub/taxonomy/gi_taxid_prot.dmp.gz");
    printv("Collecting NCBI Taxonomy Data\n");
    getFiles(\@taxFiles, "wget --passive-ftp --timeout=60 --tries=20 --recursive --no-host-directories --timestamping --cut-dirs=1 --directory-prefix=".$baseDir." --append-output=".$wget_log);
    foreach (@taxFiles){
        if(/ftp:\/\/.*?\/.+?\/(.+)$/) {
            my $file = $baseDir.$1;
	    printv("Extracting $file\n");
	    extract($file);
        } 
    } 
    printv("Finished collecting NCBI Taxonomy Data\n");

} else { 

  printv("Skipping taxonomy, as  '--taxonomy' was not specified.\n");
}
if(scalar @blocks == 0) {

    print "No blocks encountered in targets file, terminating.\n";
    exit;
}



#########################################################################################
# Write the organism.dat file, so that the specified files can be retrieved afterwards
########################################################################################

# Stores an list of all organism files that need to be processed
my @organisms;

while(@blocks) {
    
    # Get Block and bring it into hash context        
    my %block = %{shift @blocks};
    
    my $databaseName = $block{databaseName};
    my $domainName = $block{domainName};
    my $selector = $block{selector};
    printv("Obtaining file list for domain '$domainName' from database '$databaseName'\n");
    my $extractTo = $block{extractTo};

    push @organisms, $extractTo;

    getGenomeURLs($databaseName, $domainName, $selector, $extractTo);
}
#########################################################################################
# Download files
########################################################################################
if($listOnly) {
    
    print "No files will be downloaded, since '--list-only' was specified\n";
    exit;
}

while(@organisms) {

    my $organism = shift @organisms;
        
    # Open the organism.dat file and download the corresponding files
    open(my $fh, "<", "$baseDir$organism/$organismFileName")
        or die "Can't open < $baseDir$organism/$organismFileName: $!";
    while(my $line = <$fh>) {

        # Split into organism name and target file path
        my @spt  = split '\s+', $line; 

        mkpath("$baseDir$organism/$spt[0]",0, 0755);

        chdir("$baseDir$organism/$spt[0]");
        $ftp->cwd($spt[1]);
        
        # Extract the basename of the files from the filepath
        $spt[1] =~ /(\/.*)*\/(.*)/;
        
        foreach(map {$2 . $_} @filesToDownload) { 

            # The file we are looking for is actually there and we can now download it.
            if(grep /.*$_/, $ftp->ls) {

                  getFile("$ncbi/$spt[1]/$_", "wget --passive-ftp --timeout=60 --tries=20 --recursive --no-directories --no-host-directories --timestamping --cut-dirs=1 --append-output=$wget_log");
                  extract($_, 1);
            }
        }
    }
}


# Close FTP Connection
$ftp->quit;
printv("Successfully closed FTP connection to NCBI FTP Server.\n");
printv("All operations have been completed successfully.\n");
exit;


} else {

  die "ERROR  Invalid subroutine '$ARGV[1]', choose either 'list' or 'fetch'"; 
}



#########################################################################################
# ENSEMBL database selected
#########################################################################################
} elsif($ARGV[0] eq "ensembl") {
    
    
    if(@ARGV < 2) {

       die "ERROR  Please specify 'fetch'\n";
    }

    if($ARGV[1] eq "fetch") {

        print "ENSEMBL fetch"; 
    } else {


        die "Undefined subroutine";
    }
exit;


#########################################################################################
# Other database selected
#########################################################################################
} else {

    die "ERROR  Unsupported database: '$ARGV[0]', please specify 'ncbi' or 'ensembl'\n";
}
#########################################################################################
# END OF MAIN
#########################################################################################


#########################################################################################
# Core Routines
#########################################################################################

#########################################################################################
# Parses the README_assembly_summary file and returns a hash with the headers as keys
# and the allowed values as a list 
# (Lukas Zimmermann)
#########################################################################################
sub getAssemblyHeaders {

    $ftp->cwd("/genomes");
    my %index_of;
    my $handle = $ftp->retr("README_assembly_summary.txt");
    my $current_heading;
    my %allowed_values;
    my $values_follow = 0;
    my $indent;
    while(my $line = <$handle>) {
     
         if($line =~ /Column/) { 
		
     	      $line =~ /Column\s+(\d+):\s+"(.*)"/;
              $index_of{$2} = $1 - 1;
              $current_heading = $2;
              $allowed_values{$current_heading} = [];

          } elsif($line =~ /\s+Values:.*/) {
              $values_follow = 1;

          } elsif($values_follow == 1) {
          
              $line =~ /(\s+)([A-Za-z ]+)(\s+-\s+)[a-zA-z ]+/;
              $indent = length($1) + length($2) + length($3);
              push @{$allowed_values{$current_heading}}, trim($2);
              $values_follow = 2;

          } elsif($values_follow == 2 && $line =~ /(\s+)[A-Aa-z- ]+/    ) {

              if(length($1) == $indent)   {
                  next;
        
          } elsif($values_follow == 2 && $line =~ /\s+([A-Za-z ]+)\s+-\s+[a-zA-z ]+/) {
      
              push @{$allowed_values{$current_heading}}, trim($1);
          }
       } 
    }
   $ftp->abort;
   close($handle);
   return (\%index_of, \%allowed_values);
}


#########################################################################################
# Writes a list of genome files that match the given selector 
# under the given directory.
# (Lukas Zimmermann)
#########################################################################################
sub getGenomeURLs {

    my $dbName = shift; 
    my $domainName = shift;
    my $selector = shift;
    my $extractTo = shift;
    
    mkpath("$baseDir$extractTo",0, 0755);

    my $passed; 

    # Change to the correct directory and check whether species exists
    $ftp->cwd("/genomes/$dbName/$domainName") or die "ERROR  Could not change in directory 'genomes/$dbName/$domainName'";
   
    # Read the assembly summary file
    my $handle = $ftp->retr("assembly_summary.txt");

    # Note that the organism file is opened for appending
    open(my $fh, ">>", "$baseDir$extractTo/$organismFileName")
    	or die "Can't open > $baseDir$extractTo/$organismFileName: $!";

    while(my $line = <$handle>) {

        #ignore comment line
        if($line =~ /^\s*#/) {
            next;
        }
        my @spt = split $a_s_delim, $line ;

        $passed = 1;
       
        # Check whether lines matches selector String
        while (my ($header, $allowed_here) = each $selector) {
            
              my $value_here = $spt[$index_of->{$header}];
                                  
               if(not grep  /^$value_here$/, @$allowed_here) {
                  $passed = 0;       
              }
         }
         if($passed) {
                my $organismName = $spt[7];
                $organismName =~ s/\s+/_/g;
                $organismName =~ s/(\(|\)|\.)//g; # Remove parens and the dot 
                my $ftpPath = $spt[19];

                $ftpPath =~ s/ftp:\/\/ftp.ncbi.nlm.nih.gov//g;
                print $fh "$organismName\t$ftpPath\n";
         }
  }
  $ftp->abort;
  close($handle);
  close($fh);
}
#########################################################################################
# Parses the selector String and returns a hash with the headers as keys and
# the valued within arrays
# (Lukas Zimmermann)
#########################################################################################
sub parseSelectorString {
   
  my %headers;
  foreach(split '\s*:', shift) {
        my @spt = split '=', $_;

        my $header = $spt[0];
        @headers{ $spt[0] } = [split '\s*,\s*', $spt[1]];
  }
  return \%headers;
}


#########################################################################################
# Helper functions
#########################################################################################


#########################################################################################
# Only print if verbosity level is larger than 0;
#########################################################################################
sub printv {
    if($v > 0) {
        print shift;
    }
}
#########################################################################################
# Utility Function to generate the timestamp for the genomes sub folder, where
# the current snapshot of the database will be stored
#########################################################################################
sub getTimestamp{
    my($Second, $Minute, $Hour, $Day, $Month, $Year, $WeekDay, $DayOfYear, $IsDST) = localtime(time);
    $Year = $Year +1900;
    $Month++;
    return sprintf("%04u_%02u_%02u__%02u_%02u_%02u",$Year,$Month,$Day,$Hour,$Minute,$Second);
}
#########################################################################################
# Simple Download Method with additional Logging (Tries 10 times before quiting Job)
# (Christian Mayer)
#########################################################################################
sub getFiles {
    
    my @files = @{ (shift) };
    my $command = shift;
    my $count = 1;
    my $state = -1;
    foreach my $src (@files){
	while($state!=0 && $count<11){
	    if($v>0){print "Fetching $src attempt $count\n"};
	    $state=system("$command $src");
	    $count++;
	    if ($state!=0) {
		# KFT: wait some time in hope to get connected to another file server
		wait4files("-()()-");
	    }
	}
	if($state==0){
	   if($v>0){print "Success downloading $src\n"};
	    $state = -1;
	    $count = 1;
	}else{
	   if($v>0){print "Error downloading $src\n"};
	   if($v>0){print "Cmd: $command $src\n"};
	}
    }
}

sub getFile {

    my $src = shift;
    my $command = shift;
    my $count = 1;
    my $state = -1;

    while($state!=0 && $count<11){
	    if($v>0){print "Fetching $src attempt $count\n"};
	        $state=system("$command $src");
	        $count++;
	        if ($state!=0) {
		    # KFT: wait some time in hope to get connected to another file server
		    wait4files("-()()-");
	    }
	}
	if($state==0){
	   if($v>0){print "Success downloading $src\n"};
	    $state = -1;
	    $count = 1;
	}else{
	   if($v>0){print "Error downloading $src\n"};
	   if($v>0){print "Cmd: $command $src\n"};
	}
}




#########################################################################################
# Extract with tar as system command
# (Christian Mayer)
#########################################################################################
sub extract {

    my $file = shift;
    my $toDelete = shift;
    my $C = ".";
    if( $file =~/^(\/.+\/).+$/ ){ $C=$1; }   
    my $res;
    if( $file =~ /^(.+).tgz$/  or  $file =~ /^(.+).tar.gz$/ ){
	$res = system("tar -C $C -xzf $file");
    }elsif( $file =~ /^(.+).gz$/ ){
	$res = system("gzip -d -c $file > $1");
    }
    if ($res != 0) {
	die "Could not extract $file. Return code is $res.\n";
    }
    if($res == 0 and $toDelete) {
        unlink($file);
    }
}
#########################################################################################
# Determine whether the database name of NCBI is valid, return the name on success,
# otherwise throw exception
# (Lukas Zimmermann)
#########################################################################################
sub checkDatabase {

    my $name = shift;
    if(not grep( /^$name$/, @databaseNames ) ) {
     
        die "ERROR  Database name '$name' is invalid";
    }
    return $name;
}
#########################################################################################
# Utility Method to wait some time to get a more useful file server
# Input  : message to print while waiting
#########################################################################################
sub wait4files() {
    my $message=shift();
    print $message;
    sleep($sleeptime);
}

sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };


