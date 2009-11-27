=head1 NAME

VertRes::Utils::FileSystem - do filesystem manipulations

=head1 SYNOPSIS

use VertRes::Utils::FileSystem;

my $fsu = VertRes::Utils::FileSystem->new();

# ...


# generally useful file-related functions
my $base_dir = $fsu->catfile($G1K, 'META');
my @paths = $fsu->get_filepaths($base_dir, suffix => 'fastq.gz');
my ($tempfh, $tempfile) = $fsu->tempfile();
my $tempdir = $fsu->tempdir;
$fsu->rmtree($directory_structure_safe_to_delete); # !! CAREFULL !!

=head1 DESCRIPTION

Provides functions related to storing/getting things on/from the file-system.

Also provides aliases to commonly needed file-related functions: tempfile,
tempdir, catfile, rmtree.

=head1 AUTHOR

Sendu Bala: bix@sendu.me.uk

=cut

package VertRes::Utils::FileSystem;

use strict;
use warnings;

no warnings 'recursion';

use Cwd qw(abs_path);
use File::Temp;
use File::Spec;
use File::Basename;
require File::Path;
require File::Copy;
use Digest::MD5;
use Filesys::DfPortable;
use Filesys::DiskUsage qw/du/;

use base qw(VertRes::Base);

=head2 new

 Title   : new
 Usage   : my $self = $class->SUPER::new(@args);
 Function: Instantiate a new VertRes::Utils::FileSystem object.
 Returns : $self hash-ref blessed into your class
 Args    : n/a

=cut

sub new {
    my ($class, @args) = @_;
    
    my $self = $class->SUPER::new(@args);
    
    return $self;
}

=head2 get_filepaths

 Title   : get_filepaths
 Usage   : my @paths = $obj->get_filepaths('base_dir'); 
 Function: Get the absolute paths to all files in a given directory and all its
           subdirectories.
 Returns : a list of filepaths
 Args    : path to base directory
           optionally, the following named args select out only certain paths
           according to if they match the supplied regex string(s)
           filename => regex (whole basename of file must match regex)
           prefix   => regex (basename up to the final '.' must match regex)
           suffix   => regex (everything after the final '.' must match regex;
                              the '.' in .gz is not treated as the final '.' for
                              this purpose)
           dir      => regex (return directory paths that match, instead of
                              files - disables above 3 options)
           subdir   => regex (at least one of a file/dir's parent directory must
                              match regex)

=cut

sub get_filepaths {
    my ($self, $dir, %args) = @_;
    
    $dir = abs_path($dir);
    my $wanted_dir = $args{dir};
    opendir(my $dir_handle, $dir) || $self->throw("Couldn't open dir '$dir': $!");
    
    my @filepaths;
    foreach my $thing (readdir($dir_handle)) {
        next if $thing =~ /^\.+$/;
        my $orig_thing = $thing;
        $thing = $self->catfile($dir, $thing);
        
        # recurse into subdirs
        if (-d $thing) {
            if ($wanted_dir && $orig_thing =~ /$wanted_dir/) {
                if (($args{subdir} && $thing =~ /$args{subdir}/) || ! $args{subdir}) {
                    push(@filepaths, $thing);
                }
            }
            
            push(@filepaths, $self->get_filepaths($thing, %args));
            next;
        }
        
        next if $wanted_dir;
        
        # check it matches user's regexs
        my $ok = 1;
        my ($basename, $directories) = fileparse($thing);
        my $gz = '';
        if ($basename =~ s/\.gz$//) {
            $gz = '.gz';
        }
        my ($prefix, $suffix) = $basename =~ /(.+)\.(.+)$/;
        unless ($prefix) {
            # we have a .filename file
            $suffix = $basename;
        }
        $suffix .= $gz;
        $basename .= $gz;
        while (my ($type, $regex) = each %args) {
            if ($type eq 'filename') {
                $basename =~ /$regex/ || ($ok = 0);
            }
            elsif ($type eq 'prefix') {
                unless ($prefix) {
                    $ok = 0;
                }
                else {
                    $prefix =~ /$regex/ || ($ok = 0);
                }
            }
            elsif ($type eq 'suffix') {
                unless ($suffix) {
                    $ok = 0;
                }
                else {
                    $suffix =~ /$regex/ || ($ok = 0);
                }
            }
            elsif ($type eq 'subdir') {
                $directories =~ /$regex/ || ($ok = 0);
            }
        }
        
        push(@filepaths, $thing) if $ok;
    }
    
    return @filepaths;
}

=head2 tempfile

 Title   : tempfile
 Usage   : my ($handle, $tempfile) = $obj->tempfile(); 
 Function: Get a temporary filename and a handle opened for writing and
           and reading. Just an alias to File::Temp::tempfile.
 Returns : a list consisting of temporary handle and temporary filename
 Args    : as per File::Temp::tempfile

=cut

sub tempfile {
    my $self = shift;
    
    my $ft = File::Temp->new(@_);
    push(@{$self->{_fts}}, $ft);
    
    return ($ft, $ft->filename);
}

=head2 tempdir

 Title   : tempdir
 Usage   : my $tempdir = $obj->tempdir(); 
 Function: Creates and returns the name of a new temporary directory. Just an
           alias to File::Temp::tempdir.
 Returns : The name of a new temporary directory.
 Args    : as per File::Temp::tempdir

=cut

sub tempdir {
    my $self = shift;
    
    my $ft = File::Temp->newdir(@_);
    push(@{$self->{_fts}}, $ft);
    
    return $ft->dirname;
}

=head2 catfile

 Title   : catfile
 Usage   : my ($path) = $obj->catfile('dir', 'subdir', 'filename'); 
 Function: Constructs a full pathname in a cross-platform safe way. Just an
           alias to File::Spec->catfile.
 Returns : the full path
 Args    : as per File::Spec->catfile

=cut

sub catfile {
    my $self = shift;
    return File::Spec->catfile(@_);
}

=head2 rmtree

 Title   : rmtree
 Usage   : $obj->rmtree('dir'); 
 Function: Remove a full directory tree - files and subdirs. Just an alias to
           File::Path::rmtree.
 Returns : n/a
 Args    : as per File::Path::rmtree

=cut

sub rmtree {
    my $self = shift;
    return File::Path::rmtree(@_);
}

=head2 copy

 Title   : copy
 Usage   : $obj->copy('source.file', 'dest.file');
           $obj->copy('source_dir', 'dest_dir');
 Function: Copy a file and check that the copy is identical to the source
           afterwards. If given a directory as the first argument, copies all
           all the files and subdirectories (recursively), again ensuring
           copies are perfect.
 Returns : boolean (true on success; on failure the destination path won't
           exist)
 Args    : source file/dir path, output file/dir path. Optionally, the number of
           times to retry the copy if the copy isn't identical, before giving up
           (default 3).

=cut

sub copy {
    my ($self, $source, $dest, $max_retries) = @_;
    unless (defined $max_retries) {
        $max_retries = 3;
    }
    my $tmp_dest = $dest.'_copy_tmp';
    
    if (-e $dest) {
        $self->warn("destination '$dest' already exists, won't attempt to copy");
        return 0;
    }
    
    if (-d $source) {
        mkdir($tmp_dest) || $self->throw("Could not make destination directory '$tmp_dest'");
        
        unless ($self->can_be_copied($source, $tmp_dest)) {
            $self->warn("There isn't enough disk space at '$dest' to copy '$source' there");
            $self->rmtree($tmp_dest);
            return 0;
        }
        
        opendir(my $dfh, $source) || $self->throw("Could not open source directory '$source'");
        foreach my $thing (readdir($dfh)) {
            next if $thing =~ /^\.{1,2}$/;
            my $ok = $self->copy($self->catfile($source, $thing), $self->catfile($tmp_dest, $thing));
            unless ($ok) {
                $self->rmtree($tmp_dest);
                return 0;
            }
        }
        close($dfh);
        
        File::Copy::move($tmp_dest, $dest) || $self->throw("Failed to rename successfully copied directory '$tmp_dest' to '$dest'");
        return 1;
    }
    else {
        open(my $fh, '>', $tmp_dest);
        close($fh);
        unless ($self->can_be_copied($source, $tmp_dest)) {
            $self->warn("There isn't enough disk space at '$dest' to copy '$source' there");
            unlink($tmp_dest);
            return 0;
        }
        
        for (1..$max_retries) {
            my $success = File::Copy::copy($source, $tmp_dest);
            if ($success) {
                my $diff = `diff $source $tmp_dest`;
                unless ($diff) {
                    File::Copy::move($tmp_dest, $dest) || $self->throw("Failed to rename successfully copied file '$tmp_dest' to '$dest'");
                    return 1;
                }
            }
        }
        
        unlink($tmp_dest);
        return 0;
    }
}

=head2 move

 Title   : move
 Usage   : $obj->move('source.file', 'dest.file');
           $obj->move('source_dir', 'dest_dir');
 Function: Does a VertRes::Utils::FileSystem->copy on the source to the
           destination, and on success deletes the source. If the source was a
           directory in which new files were added between the start and finish
           of the copy, the destination will be deleted and source left
           untouched.
 Returns : boolean (true on success; on failure the destination path won't
           exist)
 Args    : source file/dir path, output file/dir path. Optionally, the number of
           times to retry the copy if the copy isn't identical, before giving up
           (default 3).

=cut

sub move {
    my ($self, $source, $dest, $max_retries) = @_;
    my $tmp_dest = $dest.'_move_tmp';
    
    $self->copy($source, $tmp_dest, $max_retries) || return 0;
    
    if (-d $source) {
        unless ($self->directory_structure_same($source, $tmp_dest, consider_files => 1)) {
            $self->rmtree($tmp_dest);
            $self->warn("Source directory '$source' was updated before the move completed, so the destination was deleted and the source will be left untouched");
            return 0;
        }
    }
    
    File::Copy::move($tmp_dest, $dest) || $self->throw("Failed to rename successfully moved source '$tmp_dest' to '$dest'");
    if (-d $source) {
        $self->rmtree($source);
    }
    else {
        unlink($source);
    }
    
    return 1;
}

=head2 verify_md5

 Title   : verify_md5
 Usage   : if ($obj->verify_md5($file, $md5)) { #... }
 Function: Verify that a given file has the given md5.
 Returns : boolean
 Args    : path to file, the expected md5 (hexdigest as produced by the md5sum
           program) as a string

=cut

sub verify_md5 {
    my ($self, $file, $md5) = @_;
    my $new_md5 = $self->calculate_md5($file);
    return $new_md5 eq $md5;
}

=head2 calculate_md5

 Title   : calculate_md5
 Usage   : my $md5 = $obj->calculate_md5($file)
 Function: Calculate the md5 of a file.
 Returns : hexdigest string
 Args    : path to file

=cut

sub calculate_md5 {
    my ($self, $file) = @_;
    
    open(my $fh, $file) || $self->throw("Could not open file $file");
    binmode($fh);
    my $dmd5 = Digest::MD5->new();
    $dmd5->addfile($fh);
    my $md5 = $dmd5->hexdigest;
    
    return $md5;
}

=head2 directory_structure_same

 Title   : directory_structure_same
 Usage   : if ($obj->directory_structure_same($root1, $root2)) { ... }
 Function: Find out if two directory structures are identical. (files are
           ignored by default)
 Returns : boolean
 Args    : two absolute paths to root directories to compare, optionally a hash
           of extra options:
           leaf_mtimes => \%hash (the hash ref will have a single key added to
                                  it of the first root path, where the value
                                  is another hash ref. That hash will have keys
                                  as leaf directory names and their mtimes as
                                  values)
           consider_files => boolean (default false; when true, directory
                                      structures are only considered the same if
                                      they also share the same files, and if
                                      files in the first root are all older
                                      or the same age as the corresponding file
                                      in the second root)

=cut

sub directory_structure_same {
    my ($self, $root1, $root2, %opts) = @_;
    my $orig_path = delete $opts{orig_path};
    $orig_path ||= $root1;
    
    opendir(my $dh1, $root1) || return 0;
    opendir(my $dh2, $root2) || return 0;
    
    my %checked_things;
    my $had_subdirs = 0;
    while (my $thing = readdir($dh1)) {
        next if $thing =~ /^\.{1,2}$/;
        my $this_path = File::Spec->catdir($root1, $thing);
        
        my $is_dir = -d $this_path ? 1 : 0;
        my $other_path;
        if ($is_dir) {
            $had_subdirs++;
            $other_path = File::Spec->catdir($root2, $thing);
        }
        elsif ($opts{consider_files}) {
            $other_path = File::Spec->catfile($root2, $thing);
            
            if (-e $other_path) {
                my @this_s = stat($this_path);
                my @other_s = stat($other_path);
                
                if ($this_s[9] <= $other_s[9]) {
                    $checked_things{$thing} = 1;
                    next;
                }
                else {
                    return 0;
                }
            }
            else {
                return 0;
            }
        }
        else {
            next;
        }
        
        my $thing_same = $self->directory_structure_same($this_path, $other_path, %opts, orig_path => $orig_path);
        if ($thing_same) {
            $checked_things{$thing} = 1;
        }
        else {
            return 0;
        }
    }
    
    while (my $thing = readdir($dh2)) {
        next if $thing =~ /^\.{1,2}$/;
        my $this_path = File::Spec->catdir($root2, $thing);
        next if (! $opts{consider_files} && ! -d $this_path);
        next if exists $checked_things{$thing};
        return 0;
    }
    
    if ($opts{leaf_mtimes} && ! $had_subdirs) {
        # this is a leaf directory, store that fact and its mtime
        my @s = stat($root1);
        $opts{leaf_mtimes}->{$orig_path}->{basename($root1)} = $s[9];
    }
    
    return 1;
}

=head2 hashed_path

 Title   : hashed_path
 Usage   : my $hashed_path = $obj->hashed_path('/abs/path/to/dir');
 Function: Convert a certain path to a 4-level deep hashed path based on the
           md5 digest of the input path. Eg. use the returned path as the place
           to move a directory to on a new disc, so spreading dirs out evenly
           and not having too many dirs in a single folder.
 Returns : string
 Args    : absolute path

=cut

sub hashed_path {
    my ($self, $path) = @_;
    my $dmd5 = Digest::MD5->new();
    $dmd5->add($path);
    my $md5 = $dmd5->hexdigest;
    my @chars = split("", $md5);
    my $basename = basename($path);
    return $self->catfile(@chars[0..3], $basename);
}

=head2 can_be_copied

 Title   : can_be_copied
 Usage   : if ($obj->can_be_copied('/abs/.../source', '/abs/.../dest')) { ... }
 Function: Find out of there is enough disc space at a destination to copy
           a source directory/file to.
 Returns : boolean
 Args    : two absolute paths (source and destination)

=cut

sub can_be_copied {
    my ($self, $source, $destination) = @_;
    my $usage = $self->disk_usage($source) || 0;
    my $available = $self->disk_available($destination) || return 0;
    return $available > $usage;
}

=head2 disk_available

 Title   : disk_available
 Usage   : my $bytes_left = $obj->disk_available('/path');
 Function: Find out how much disk space is available on the disk the supplied
           path is mounted on. This is how much is available to the current
           user (so considers quotas), not the total free space on the disk.
 Returns : int
 Args    : path string

=cut

sub disk_available {
    my ($self, $path) = @_;
    my $ref = dfportable($path) || (return 0);
    return $ref->{bavail};
}

=head2 disk_usage

 Title   : disk_usage
 Usage   : my $bytes_used = $obj->disk_usage('/path');
 Function: Find out how much disk space a file or directory is using up.
 Returns : int
 Args    : path string

=cut

sub disk_usage {
    my ($self, $path) = @_;
    my $total = du($path);
    return $total || 0;
}

1;