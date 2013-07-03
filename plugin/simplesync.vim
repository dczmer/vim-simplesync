" simplesync.vim
"
" TODO:
" shell calls with `` do not return an error code. fix.
"
" ABOUT:
"
" This plugin will install all files in open buffers to their destination
" directories.
"
" THIS IS NOT A SUBSTITUTE FOR RUNNING MAKE!
" This will only copy out files that are in open buffers, and only for
" those file which match the rules you explicitly defined in the config.
"
" SYNOPSIS:
"
" # refresh the simple sync mappings (done automatically on load of plugin)
" :call SimpleSyncRefresh()
"
" # sync the current buffer to its destination path
" :call SimpleSync()
"
" # sync a specific buffer to its destination path
" :call SimpleSyncN($buffer_number)
"
" # sync ALL open buffers to their destination paths
" :call SimpleSyncAll()
"
" USE:
"
" Enable this plugin by adding the following to your vimrc
"
"   let g:use_simple_sync=1
"
" Start by definging a map file somewhere and setting a global variable
" g:simple_sync_config to point to it.
"
"   let g:simple_sync_config="~/.simple_sync_config"
"
" This file should contain a JSON array of path patterns that match against
" a full file path and point to a destination directory. This is an array
" and not a hash, because hashes are not guaranteed to preserve order, and
" the array is. This allows you to 'chain' rules similar to the way iptables
" rules work. The first match will be used to determine the destination.
"
" Example (~/simple_sync_config):
"   [
"       [ "main\\/perllib(\\/.*\\.pm)$",       "$FIRMWARE/lib/perl5"   ],
"       [ "web\\/cgi-bin(\\/.*\\.cgi)$",       "$FIRMWARE/web/cgi-bin" ],
"       [ "web\\/js(\\/.*\\.js)$",             "$FIRMWARE/web/js"      ],
"       [ "web\\/locale(\\/.*\\.txt)$",        "$FIRMWARE/web/locale"  ],
"       [ "web\\/etc(\\/.*\\.xml)$",           "$FIRMWARE/etc"         ]
"   ]
"
" If the g:simple_sync_config environment variable is not set, does not point to
" an existing file, or does not contain a valid JSON array of 2-element
" sub-arrays, then $simple_sync_map will remain an empty hash reference and no
" path matches will succeed (does nothing).
"
" Once the $simple_sync_map hash has been loaded by calling SimpleSyncRefresh(),
" subsequent calls to SimpleSync() will use those cached values to perform the
" path matching.
"
" SimpleSync() will evaluate the full path and file name for each open buffer
" and look for a matching rule in $simple_sync_map by looking at the first
" element of each subarray (the source pattern), in order. The source pattern 
" is matched against the buffer's path and file name as a regular expression 
" and, if it matches, the second element in the sub-array is the base
" destination path. If no match is found then no action will be taken for this
" buffer.
"
" Once a destination base path is found the SimpleSync() method will then use
" the captured $1 value from the source pattern match and append it to the
" value of the second sub-array element (the destination base path) to produce
" the final destination path.
"
" Finally, SimpleSync() will check the timestamps of the source file and the
" destination file and will only install the new version if it is newer than
" the destination version. If the destination directory does not exist it will
" be created with 'mkdir -p'.
"

if has("perl") && exists("g:use_simple_sync") && g:use_simple_sync==1 && !exists("g:simple_sync_loaded")

perl <<EOF

use JSON::XS;

# local cache of path mappings
our $simple_sync_map = [];

sub get_install_info {
    my ($buffer_number) = @_;
    return unless (@$simple_sync_map);
    my $source_path = VIM::Eval("expand('#$buffer_number:p:h')");
    my $source_file = VIM::Eval("expand('#$buffer_number:p:t')");
    return resolve_install_info($source_path, $source_file);
}

# figure out the various source and destination path parts.
sub resolve_install_info {
    my ($source_path, $source_file) = @_;
    my $full_source = $source_path . "/" . $source_file;
    foreach my $row (@$simple_sync_map) {
        if ($full_source =~ /$row->[0]/) {
            my $captured = $1;
            my $full_dest = $row->[1] . $captured;
            $full_dest =~ s/$source_file$//;
            return {
                source_path => $source_path,
                source_file => $source_file,
                full_source => $full_source,
                captured => $captured,
                dest => $full_dest,
                full_dest => $full_dest . $source_file,
            };
        }
    }
}

# check the file's path, if it does not exist create it.
sub ensure_path_exists {
    my ($full_dest) = @_;
    $full_dest =~ /^(.*)\/[^\/]+$/;
    my $dest_path = $1;
    if ($dest_path && !-e $dest_path) {
        VIM::Msg("mkdir -p $dest_path");
        `mkdir -p $dest_path`;
    }
}

# make the destination path if it does not exist, install the file if it does
# not exist, or install the file if it does exist but is out of date.
sub sync_file {
    my ($install_info) = @_;
    ensure_path_exists($install_info->{full_dest}); 
    my $from = $install_info->{full_source};
    my $to = $install_info->{full_dest};
    if (!-e $to) {
        VIM::Msg("installing $from -> $to");
        `cp -p $from $to`;
    }
    elsif ((stat($from))[9] > (stat($to))[9]) {
        VIM::Msg("updating $from -> $to");
        `if [ $from -nt $to ]; then cp -p $from $to; fi`
    }
}

sub diff_file {
    my ($install_info) = @_;
    # TODO: this does not output to VIM::Msg
    my @lines = `diff $install_info->{full_source} $install_info->{full_dest}`;
    VIM::Msg(join("\n" => @lines));
}

EOF

" sync all open buffers
function! SimpleSyncAll()
perl <<EOF
    foreach my $buff (VIM::Buffers()) {
        my $num = $buff->Number();
        VIM::DoCommand("call SimpleSyncN($num)");
    }
EOF
endfunction

function! SimpleSync()
perl <<EOF
    my $buffer_number = $curbuf->Number();
    VIM::DoCommand("call SimpleSyncN($buffer_number)");
EOF
endfunction

" compares the current path against each source pattern in the hash
" map $simple_sync_map, uses the match to construct a destination path
function! SimpleSyncN(buffer_number)
perl <<EOF
    my $buffer_number = VIM::Eval('a:buffer_number');
    my $install_info = get_install_info($buffer_number);
    if ($install_info) {
        sync_file($install_info);
    }
EOF
endfunction

function! SimpleSyncDiff(buffer_number)
perl <<EOF
    my $buffer_number = VIM::Eval('a:buffer_number');
    my $install_info = get_install_info($buffer_number);
    if ($install_info) {
        diff_file($install_info);
    }
EOF
endfunction

" refreshes the mappings of source path patterns to destinations.
"
" if the envrironment variable $SIMPLE_SYNC_CONFIG and points to an
" existing file, load the contents of the file into the $simple_sync_map
" hash map.
"
" if we fail to get anything useful out of that file then set
" $simple_sync_map to an empty hash.
function! SimpleSyncRefresh()
    if !exists("g:simple_sync_config")
        echo "No simple_sync_config set. Functionality disabled."
    else
perl <<EOF
    my $config_path = VIM::Eval('g:simple_sync_config');
    unless ($config_path && -e $config_path) {
        VIM::Msg("No g:simple_sync_config set.");
        return;
    }
    $simple_sync_map = [];
    # load pattern map json from $SIMPLE_SYNC_CONFIG
    open(my $FH, "<", $config_path);
    if (!$FH) {
        $simple_sync_map = [];
        VIM::Msg("Failed to open simple_sync_config file: $config_path.");
        return;
    }
    my @json = <$FH>;
    $simple_sync_map = decode_json( join("\n", @json) );
    close($FH);
    # TODO: change this to if (!verify_sync_map($simple_sync_map))
    # include check that contains only arrays and each sub-array
    # has two scalar elements only
    if (!$simple_sync_map || ref($simple_sync_map) ne "ARRAY") {
        $simple_sync_map = [];
    }
EOF
    endif
endfunction

" initialize the path map
call SimpleSyncRefresh()

let g:simple_sync_loaded=1

endif " !exists g:simple_sync_loaded
