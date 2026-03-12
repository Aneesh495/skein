use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd);
use JSON::PP;
use Skein::CLI;
use Skein::Util qw(write_text decode_json_file);

sub invoke {
    my (@arguments)=@_;
    my ($stdout,$stderr)=('','');
    open my $out,'>',\$stdout or die $!;
    open my $err,'>',\$stderr or die $!;
    local *STDOUT=$out;
    local *STDERR=$err;
    my $status=Skein::CLI->main(\@arguments);
    return ($status,$stdout,$stderr);
}
my $dir=tempdir(CLEANUP=>1);
my @commands=(
    ['check','examples/rack.sk'],
    ['run','examples/rack.sk','--backend','oracle'],
    ['explain','examples/rack.sk'],
    ['cuts','examples/rack.sk','--signed'],
    ['importance','examples/rack.sk','--shapley'],
    ['polynomial','examples/rack.sk'],
    ['spectrum','examples/rack.sk'],
    ['plan','examples/rack.sk','--budget','11','--target','0'],
    ['plan','examples/rack.sk','--budget','11','--robust'],
    ['bounds','examples/rack.sk'],
    ['policy','examples/diagnosis.sk','--budget','12'],
    ['sample','examples/rack.sk','--samples','8','--seed','contract'],
    ['order','examples/rack.sk'],
    ['effect','examples/rack.sk','power','outage'],
    ['mission','examples/mission.json'],
    ['compare','examples/rack.sk','examples/rack.sk','--expr','outage'],
    ['export','examples/rack.sk'],
);
for my $arguments (@commands) {
    my ($code,$out,$err)=invoke(@$arguments,'--json');
    is($code,0,"$arguments->[0] succeeds");
    is($err,'',"$arguments->[0] produces no warning");
    my $data=eval { JSON::PP->new->decode($out) };
    ok(!$@ && ref($data) eq 'HASH',"$arguments->[0] emits complete JSON");
}
for my $command (qw(dot source network report)) {
    my $input=$command eq 'network'?'examples/bridge.json':'examples/rack.sk';
    my ($code,$out,$err)=invoke($command,$input,'--out',"$dir/$command.txt");
    is($code,0,"$command output command");
    is($err,'',"$command no warnings");
    ok(-s "$dir/$command.txt","$command saved atomically");
}
my $markov={states=>[qw(healthy failed)],transitions=>[['9/10','1/10'],['1/2','1/2']],
    targets=>['failed'],rewards=>{healthy=>1},horizon=>4};
write_text("$dir/markov.json",JSON::PP->new->encode($markov));
my ($code,$out,$err)=invoke('markov',"$dir/markov.json",'--json');
is($code,0,'Markov CLI contract');
is($err,'','Markov CLI no warning');
for my $arguments (
    ['unknown','examples/rack.sk'],['run'],['check','examples/rack.sk','extra'],
    ['run','examples/rack.sk','absent'],['run','examples/rack.sk','--unknown'],
    ['effect','examples/rack.sk','power'],['network','examples/bridge.json','extra'],
    ['verify','examples/rack.sk','missing.json'],
    ['sample','examples/rack.sk','--samples','0']) {
    my ($code,$out,$err)=invoke(@$arguments);
    ok($code!=0,"$arguments->[0] invalid invocation has failure status");
    is($out,'',"$arguments->[0] does not print a successful partial result");
    like($err,qr/\S/,"$arguments->[0] diagnostic present");
}
write_text("$dir/impossible.sk",'noise u ~ 0; query q = P(1) given(u);');
($code,$out,$err)=invoke('run',"$dir/impossible.sk");
is($code,4,'impossible evidence exit contract');
is($out,'','impossible query does not emit a result');
my $binary=File::Spec->rel2abs('bin/skein');
my $example=File::Spec->rel2abs('examples/rack.sk');
my $previous=getcwd;
chdir $dir or die $!;
open my $process,'-|',$^X,$binary,'run',$example,'baseline' or die "cannot start CLI: $!";
my $process_output=do { local $/; <$process> };
close $process;
my $status=$?;
chdir $previous or die $!;
is($status,0,'real CLI process works from another directory');
like($process_output,qr/2599\/250000/,'real CLI process computes baseline');
done_testing;
