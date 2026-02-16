use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Skein::CLI;
use Skein::Util qw(decode_json_file);

sub invoke {
    my (@args) = @_;
    my ($stdout, $stderr) = ('','');
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    my $code = Skein::CLI->main(\@args);
    return ($code,$stdout,$stderr);
}

my ($code,$out,$err) = invoke('run','examples/rack.sk','baseline');
is($code,0,'CLI run');
like($out,qr/baseline = 2599\/250000/,'CLI exact baseline');
is($err,'','no warnings');
($code,$out,$err) = invoke('run','examples/rack.sk','baseline','--backend','factor');
is($code,0,'factor CLI');
like($out,qr/2599\/250000/,'factor exact baseline');
my $dir = tempdir(CLEANUP => 1);
($code,$out,$err) = invoke('certificate','examples/rack.sk','baseline','--out',"$dir/cert.json");
is($code,0,'certificate CLI');
ok(-f "$dir/cert.json",'certificate saved');
($code,$out,$err) = invoke('verify','examples/rack.sk',"$dir/cert.json");
is($code,0,'certificate verify CLI');
like($out,qr/Verified 8 worlds/,'complete verification reported');
($code,$out,$err) = invoke('run','examples/rack.sk','--expr','outage & !outage');
is($code,0,'manual expression');
like($out,qr/ = 0/,'manual contradiction probability');
($code,$out,$err) = invoke('run','missing.sk');
is($code,2,'missing file error');
($code,$out,$err) = invoke('--version');
is($code,0,'global version option');
like($out,qr/skein 0\.1\.0/,'version displayed');
($code,$out,$err) = invoke('run','examples/rack.sk','baseline','--max-nodes','2');
is($code,3,'resource error distinct');
($code,$out,$err) = invoke('run','examples/rack.sk','baseline','--backend','other');
is($code,2,'unsupported backend rejected');
($code,$out,$err) = invoke('explain','examples/voter.sk');
is($code,0,'default query resolution');
done_testing;
