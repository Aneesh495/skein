use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Skein::Model;
use Skein::Engine;
use Skein::Expr qw(const var op validate);
use Skein::BDD;
use Skein::BDD::Transform qw(import_diagram);
use Skein::ZDD;
use Skein::Factor;
use Skein::Linear qw(matrix solve);
use Skein::Markov;
use Skein::RNG;
use Skein::Rat qw(rat probability text mul);
use Skein::Util qw(deep_copy read_text write_text decode_json_file);

sub rejected {
    my ($name,$code,$pattern) = @_;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings,$_[0] };
    my $ok = eval { $code->(); 1 };
    ok(!$ok,"$name rejected");
    like($@,$pattern,"$name diagnostic") if $pattern;
    is_deeply(\@warnings,[],"$name no runtime warnings");
}

for my $value (undef,[],{},'NaN','Inf','1e3','2/0','0/0',' 1/2','1/2 ','--1','1//2','', '٠/١', '١.٥') {
    my $label = !defined($value) ? 'undefined' : ref($value) || $value;
    $label =~ s/([^\x20-\x7e])/sprintf('U+%04X',ord($1))/ge;
    rejected("nonrational input $label",sub { rat($value) });
}
for my $value ('-1/100','101/100','2') {
    rejected('out-of-range probability',sub { probability($value) },qr/outside/);
}
my $base = {noise => [{name => 'u',p => '1/2'}],nodes => [{name => 'x',expr => var('u')}],
    queries => [{name => 'q',event => var('x')}]};
my @model_mutations = (
    ['unknown root field',sub { $_[0]{unexpected}=1 },qr/unknown model field/],
    ['unsupported schema',sub { $_[0]{schema}='future' },qr/unsupported model schema/],
    ['null title',sub { $_[0]{title}=undef },qr/invalid model title/],
    ['object title',sub { $_[0]{title}={} },qr/invalid model title/],
    ['wrong noise container',sub { $_[0]{noise}={} },qr/noise must be an array/],
    ['wrong node container',sub { $_[0]{nodes}=1 },qr/nodes must be an array/],
    ['duplicate variable',sub { push @{$_[0]{noise}},{name=>'x',p=>'1/2'} },qr/duplicate variable/],
    ['dangling equation',sub { $_[0]{nodes}[0]{expr}=var('absent') },qr/unknown variable/],
    ['cycle',sub { $_[0]{nodes}[0]{expr}=var('x') },qr/cycle/],
    ['missing query event',sub { delete $_[0]{queries}[0]{event} },qr/missing query field/],
    ['missing query name',sub { delete $_[0]{queries}[0]{name} },qr/invalid query name/],
    ['duplicate query',sub { push @{$_[0]{queries}},deep_copy($_[0]{queries}[0]) },qr/duplicate query/],
    ['noise intervention',sub { $_[0]{queries}[0]{interventions}={u=>0} },qr/must be endogenous/],
    ['null evidence',sub { $_[0]{queries}[0]{evidence}=undef },qr/expression must be an object/],
    ['incomplete order',sub { $_[0]{order}=[] },qr/include every noise/],
    ['duplicate order',sub { $_[0]{order}=['u','u'] },qr/duplicate order/],
    ['endogenous order',sub { $_[0]{order}=['x'] },qr/non-noise/],
    ['unknown interval',sub { $_[0]{intervals}={missing=>[0,1]} },qr/unknown noise/],
    ['reversed interval',sub { $_[0]{intervals}={u=>['3/4','1/4']} },qr/reversed/],
    ['excluded nominal',sub { $_[0]{intervals}={u=>[0,'1/4']} },qr/outside interval/],
    ['noise repair',sub { $_[0]{repairs}=[{name=>'r',node=>'u',value=>0,cost=>1}] },qr/endogenous/],
    ['negative cost',sub { $_[0]{sensors}=[{name=>'s',expr=>var('x'),cost=>-1}] },qr/invalid sensor cost/],
);
for my $case (@model_mutations) {
    my $raw = deep_copy($base);
    $case->[1]->($raw);
    rejected($case->[0],sub { Skein::Model->new($raw) },$case->[2]);
}
for my $ast (undef,[],{}, {op=>'alien'}, {op=>'const',value=>2},
    {op=>'var',name=>'bad name'}, {op=>'not',args=>[]},
    {op=>'atleast',k=>2,args=>[const(1)]}, {op=>'and',args=>[var('u'),var('u')],extra=>1}) {
    rejected('invalid AST',sub { validate($ast) });
}
my $deep = var('u');
$deep = {op=>'not',args=>[$deep]} for 1 .. 130;
rejected('AST depth bound',sub { validate($deep) },qr/depth limit/);
for my $source ('noise u ~ 1/0;','noise u ~ 1/2','node x = missing;',
    'query q = P(1) given(1) given(0);','query q = P(1) do(x=1,x=0);',
    'node x = eval("bad");','noise u ~ 1e-3;','node x = (1 & );',
    'node x = ite(1,0);','query q = P(1); trailing',
    'title "unterminated;','title "bad\\q";') {
    rejected('malformed source',sub { Skein::Model->from_text($source) });
}
my $bdd = Skein::BDD->new([qw(a b)]);
my $a = $bdd->variable('a');
my $b = $bdd->variable('b');
rejected('BDD backward rank',sub { $bdd->mk(1,$a,1) },qr/order/);
rejected('BDD bad id',sub { $bdd->node(1000) },qr/invalid BDD node id/);
rejected('BDD bad value',sub { $bdd->evaluate($a,{a=>2,b=>0}) },qr/Boolean/);
rejected('BDD missing value',sub { $bdd->evaluate($a,{b=>0}) },qr/missing/);
rejected('BDD unknown operation',sub { $bdd->apply('unknown',$a,$b) },qr/invalid Boolean truth table/);
rejected('BDD duplicate variables',sub { Skein::BDD->new([qw(a a)]) },qr/duplicate/);
my $diagram = {schema=>'skein.bdd/1',variables=>['a'],nodes=>[{id=>2,rank=>0,low=>0,high=>0}],roots=>[2]};
rejected('unreduced serialized diagram',sub { import_diagram($diagram) },qr/unreduced/);
my $zdd = Skein::ZDD->new([qw(a b)]);
rejected('ZDD duplicate set element',sub { $zdd->singleton([qw(a a)]) },qr/duplicate/);
rejected('ZDD unknown set element',sub { $zdd->singleton(['x']) },qr/unknown/);
rejected('factor duplicate scope',sub { Skein::Factor->new([qw(a a)],{}) },qr/duplicate/);
rejected('factor negative weight',sub { Skein::Factor->new(['a'],{'1'=>-1}) },qr/negative/);
rejected('factor malformed key',sub { Skein::Factor->new(['a'],{'11'=>1}) },qr/assignment/);
for my $matrix (undef,{},[1],[undef],[[],[1]],[[1,2],[1]]) {
    rejected('invalid matrix shape',sub { matrix($matrix) });
}
rejected('singular unique solve',sub { solve([[1,1],[2,2]],[1,2]) },qr/no unique solution/);
rejected('Markov negative row',sub { Skein::Markov->new([qw(a b)],[[-1,2],[0,1]]) },qr/outside/);
rejected('Markov unnormalized row',sub { Skein::Markov->new([qw(a b)],[[0,0],[0,1]]) },qr/stochastic/);
my $chain = Skein::Markov->new([qw(a b)],[[0,1],[0,1]]);
rejected('unknown Markov target',sub { $chain->first_passage(['x'],1) },qr/unknown/);
rejected('unnormalized initial distribution',sub { $chain->distribution(1,[0,0]) },qr/normalized/);
rejected('Markov step bound',sub { $chain->distribution(1000) },qr/invalid Markov horizon/);
my $unicode = Skein::RNG->new('雪');
my $large = '1/' . ('9' x 2000);
is(text(rat($large)),$large,'long exact intermediate result can be parsed again');
is(text(mul($large,0)),'0','long exact result preserves zero multiplication');
is($unicode->bytes(32),Skein::RNG->new('雪')->bytes(32),'Unicode seeds produce stable UTF-8 streams');
my $dir = tempdir(CLEANUP=>1);
write_text("$dir/unicode.txt","雪\n");
is(read_text("$dir/unicode.txt"),"雪\n",'UTF-8 boundary round trip');
write_text("$dir/data.json",'{invalid}');
rejected('invalid JSON file',sub { decode_json_file("$dir/data.json") },qr/invalid JSON/);
rejected('file byte bound',sub { read_text("$dir/unicode.txt",1) },qr/byte limit/);
done_testing;
