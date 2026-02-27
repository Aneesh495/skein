use strict;
use warnings;
use Test::More;
use Skein::Network;
use Skein::Generate;
use Skein::Engine;
use Skein::Util qw(decode_json_file);

my $network = Skein::Network->new(decode_json_file('examples/bridge.json'));
is($network->verify->{worlds},64,'all bridge worlds checked by BFS');
ok($network->verify(interventions => {edge_failed_0 => 0})->{verified},'restored physical edge checked');
ok($network->verify(interventions => {domain_failed_0 => 0})->{verified},'isolated fault domain checked');
my $generator = Skein::Generate->new(seed => 'network-check');
for my $i (1 .. 5) {
    my $spec = $generator->network(vertices => 4);
    $spec->{directed} = $i % 2;
    ok(Skein::Network->new($spec)->verify->{verified},"generated physical network $i");
}
my $parallel = Skein::Network->new({vertices => [qw(a b)],source => 'a',target => 'b',
    edges => [{name => 'first',from => 'a',to => 'b',p => '1/2'},
              {name => 'second',from => 'a',to => 'b',p => '1/3'}]});
is(Skein::Engine->new($parallel->model)->solve('baseline')->{probability},'1/6','parallel links combined before closure');
my $empty = Skein::Network->new({vertices => [qw(a b)],source => 'a',target => 'b',edges => []});
is(Skein::Engine->new($empty->model)->solve('baseline')->{probability},'1','disconnected network has certain outage');
ok($empty->verify->{verified},'zero-noise network checked');
eval { $network->connected({}, {}) };
like($@,qr/missing domain noise/,'missing realization rejected');
eval { $network->verify(interventions => {connected => 1}) };
like($@,qr/only accepts edge or domain/,'physical checker refuses artificial reachability changes');
done_testing;
