package Skein::Render;
use 5.020;
use strict;
use warnings;
use Scalar::Util qw(refaddr);
use Skein::Util qw(xml_escape integer);
use Skein::Expr qw(render);
use Skein::Rat ();

sub _dot_string {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\n/\\n/g;
    return '"' . $value . '"';
}

sub model_dot {
    my ($class, $model) = @_;
    my $graph = $model->graph;
    my $priors = $model->priors;
    my @lines = ('digraph skein {', '  rankdir=TB;', '  graph [bgcolor="transparent"];',
        '  node [fontname="monospace", shape=box, style="rounded"];');
    for my $name (@{$graph->nodes}) {
        my $label = $name;
        $label .= "\np=" . $priors->{$name} if exists $priors->{$name};
        my $color = exists($priors->{$name}) ? '#bbd7cc' : '#ded9cd';
        push @lines, '  ' . _dot_string($name) . ' [label=' . _dot_string($label)
            . ', style="rounded,filled", fillcolor="' . $color . '"];';
    }
    for my $edge (@{$graph->edges}) {
        push @lines, '  ' . _dot_string($edge->[0]) . ' -> ' . _dot_string($edge->[1]) . ';';
    }
    push @lines, '}';
    return join("\n", @lines) . "\n";
}

sub diagram_dot {
    my ($class, $bdd, $root) = @_;
    my $variables = $bdd->variables;
    my @lines = ('digraph decision_diagram {', '  rankdir=TB;',
        '  node [fontname="monospace", shape=circle];');
    for my $id (@{$bdd->reachable($root)}) {
        my $label = $id < 2 ? "$id" : $variables->[$bdd->node($id)->[0]];
        my $shape = $id < 2 ? 'box' : 'circle';
        push @lines, "  n$id [label=" . _dot_string($label) . ", shape=$shape];";
        if ($id >= 2) {
            my ($rank, $low, $high) = @{$bdd->node($id)};
            push @lines, "  n$id -> n$low [label=\"0\", style=dashed];";
            push @lines, "  n$id -> n$high [label=\"1\"];";
        }
    }
    push @lines, '  root [shape=plaintext, label="query"];', "  root -> n$root;", '}';
    return join("\n", @lines) . "\n";
}

sub _svg_start {
    my ($width, $height, $label) = @_;
    return '<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="'
        . xml_escape($label) . '" viewBox="0 0 ' . $width . ' ' . $height
        . '" width="' . $width . '" height="' . $height . '">'
        . '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" '
        . 'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
        . '<path d="M 0 0 L 10 5 L 0 10 z" fill="#8b958f"/></marker></defs>';
}

sub _label {
    my ($text, $maximum) = @_;
    $maximum //= 25;
    return length($text) > $maximum ? substr($text,0,$maximum-3) . '...' : $text;
}

sub model_svg {
    my ($class, $model, %options) = @_;
    my $graph = $model->graph;
    my $limit = integer($options{max_nodes} // 100, 'graph rendering limit', 1, 1000);
    die "graph rendering node limit exceeded\n" if @{$graph->nodes} > $limit;
    my %level;
    for my $name (@{$graph->topological}) {
        my $maximum = -1;
        for my $parent (@{$graph->parents($name)}) {
            $maximum = $level{$parent} if $level{$parent} > $maximum;
        }
        $level{$name} = $maximum + 1;
    }
    my %layers;
    push @{$layers{$level{$_}}}, $_ for @{$graph->nodes};
    my $max_layer = 0;
    my $max_count = 1;
    for my $layer (keys %layers) {
        $max_layer = $layer if $layer > $max_layer;
        $max_count = @{$layers{$layer}} if @{$layers{$layer}} > $max_count;
    }
    my $width = $max_count * 210 + 40;
    $width = 480 if $width < 480;
    my $height = ($max_layer + 1) * 110 + 50;
    my %positions;
    for my $layer (sort { $a <=> $b } keys %layers) {
        my @names = sort @{$layers{$layer}};
        my $offset = ($width - @names * 210) / 2;
        for my $i (0 .. $#names) {
            $positions{$names[$i]} = [$offset + $i * 210 + 15, 25 + $layer * 110];
        }
    }
    my $svg = _svg_start($width,$height,'Structural causal graph for ' . $model->name);
    for my $edge (@{$graph->edges}) {
        my ($from,$to) = @$edge;
        my ($x1,$y1) = @{$positions{$from}};
        my ($x2,$y2) = @{$positions{$to}};
        $x1 += 90;
        $x2 += 90;
        $y1 += 56;
        my $middle = ($y1 + $y2) / 2;
        $svg .= '<path d="M' . "$x1 $y1 C$x1 $middle $x2 $middle $x2 $y2"
            . '" fill="none" stroke="#9ca69f" stroke-width="1.5" marker-end="url(#arrow)"/>';
    }
    my $priors = $model->priors;
    for my $name (@{$graph->nodes}) {
        my ($x,$y) = @{$positions{$name}};
        my $noise = exists $priors->{$name};
        my $fill = $noise ? '#e5efe8' : '#faf7f0';
        my $stroke = $noise ? '#90aa98' : '#c8c1b3';
        $svg .= '<g><title>' . xml_escape($name) . '</title><rect x="' . $x . '" y="' . $y
            . '" width="180" height="56" rx="7" fill="' . $fill . '" stroke="' . $stroke . '"/>';
        $svg .= '<text x="' . ($x+90) . '" y="' . ($y+23)
            . '" text-anchor="middle" font-family="monospace" font-size="12" fill="#20372a">'
            . xml_escape(_label($name,23)) . '</text>';
        $svg .= '<text x="' . ($x+90) . '" y="' . ($y+42)
            . '" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#687269">'
            . ($noise ? 'independent noise / p=' . xml_escape($priors->{$name}) : 'structural equation')
            . '</text></g>';
    }
    return $svg . '</svg>';
}

sub diagram_svg {
    my ($class, $bdd, $root, %options) = @_;
    my $reachable = $bdd->reachable($root);
    my $limit = integer($options{max_nodes} // 120, 'diagram rendering limit', 1, 1000);
    die "diagram rendering node limit exceeded\n" if @$reachable > $limit;
    my %layers;
    for my $id (@$reachable) {
        push @{$layers{$bdd->node($id)->[0]}}, $id;
    }
    my @ranks = sort { $a <=> $b } keys %layers;
    my $maximum = 1;
    for my $rank (@ranks) {
        $maximum = @{$layers{$rank}} if @{$layers{$rank}} > $maximum;
    }
    my $width = $maximum * 190 + 50;
    $width = 430 if $width < 430;
    my $height = @ranks * 105 + 35;
    my %position;
    for my $layer (0 .. $#ranks) {
        my @ids = sort { $a <=> $b } @{$layers{$ranks[$layer]}};
        my $offset = ($width - @ids * 190) / 2;
        for my $i (0 .. $#ids) {
            $position{$ids[$i]} = [$offset+$i*190+95, 40+$layer*105];
        }
    }
    my $svg = _svg_start($width,$height,'Reduced ordered decision diagram');
    for my $id (@$reachable) {
        next if $id < 2;
        my ($rank,$low,$high) = @{$bdd->node($id)};
        my ($x,$y) = @{$position{$id}};
        for my $value (0,1) {
            my $child = $value ? $high : $low;
            my ($cx,$cy) = @{$position{$child}};
            my $dash = $value ? '' : ' stroke-dasharray="4 4"';
            $svg .= '<path d="M' . "$x " . ($y+20) . ' L' . "$cx " . ($cy-20)
                . '" stroke="' . ($value ? '#577a63' : '#aaa394') . '" stroke-width="1.5"'
                . $dash . ' fill="none" marker-end="url(#arrow)"/>';
            $svg .= '<text x="' . (($x+$cx)/2 + ($value ? 7 : -10)) . '" y="' . (($y+$cy)/2)
                . '" font-family="monospace" font-size="11" fill="#6a746b">' . $value . '</text>';
        }
    }
    my $variables = $bdd->variables;
    for my $id (@$reachable) {
        my ($x,$y) = @{$position{$id}};
        my $label = $id < 2 ? ($id ? 'true' : 'false') : $variables->[$bdd->node($id)->[0]];
        $svg .= '<g><title>' . xml_escape($label) . '</title><rect x="' . ($x-76) . '" y="' . ($y-20)
            . '" width="152" height="40" rx="' . ($id<2 ? 3 : 20)
            . '" fill="' . ($id==0 ? '#f4e8df' : $id==1 ? '#e0eddf' : '#faf7f0') . '" stroke="#a6b5a8"/>';
        $svg .= '<text x="' . $x . '" y="' . ($y+4)
            . '" text-anchor="middle" font-family="monospace" font-size="11" fill="#294632">'
            . xml_escape(_label($label,20)) . '</text></g>';
    }
    return $svg . '</svg>';
}

sub risk_bars {
    my ($class, $rows, %options) = @_;
    my $width = 720;
    my $height = 42 * @$rows + 25;
    my $svg = _svg_start($width,$height,'Exact query probabilities, with approximate visual bar lengths');
    for my $i (0 .. $#$rows) {
        my $row = $rows->[$i];
        my $p = Skein::Rat::rat($row->{probability})->numify;
        my $y = 17 + 42 * $i;
        $svg .= '<text x="0" y="' . ($y+11) . '" font-family="monospace" font-size="12" fill="#38533d">'
            . xml_escape(_label($row->{name},25)) . '</text>';
        $svg .= '<rect x="215" y="' . $y . '" width="330" height="18" rx="3" fill="#ece8dd"/>';
        $svg .= '<rect x="215" y="' . $y . '" width="' . (330*$p) . '" height="18" rx="3" fill="#5d7e65"/>';
        $svg .= '<text x="560" y="' . ($y+13) . '" font-family="monospace" font-size="12" fill="#223e2c">'
            . xml_escape($row->{probability}) . '</text>';
    }
    return $svg . '</svg>';
}

sub frontier_svg {
    my ($class, $frontier) = @_;
    my ($width,$height) = (620,300);
    my $maximum_cost = 1;
    for my $point (@$frontier) {
        $maximum_cost = $point->{cost} if $point->{cost} > $maximum_cost;
    }
    my $svg = _svg_start($width,$height,'Exact repair cost versus residual risk frontier');
    $svg .= '<path d="M60 25 V245 H585" fill="none" stroke="#99a396"/>';
    for my $tick (0 .. 4) {
        my $y = 245 - 220 * $tick/4;
        $svg .= '<path d="M60 ' . $y . ' H585" stroke="#e5e4da"/>';
        $svg .= '<text x="50" y="' . ($y+4) . '" text-anchor="end" font-family="monospace" font-size="10">'
            . ($tick*25) . '%</text>';
    }
    my @points;
    for my $point (@$frontier) {
        my $x = 60 + 525 * $point->{cost}/$maximum_cost;
        my $y = 245 - 220 * Skein::Rat::rat($point->{probability})->numify;
        push @points, "$x,$y";
    }
    $svg .= '<polyline points="' . join(' ',@points) . '" fill="none" stroke="#557862" stroke-width="2"/>' if @points;
    for my $i (0 .. $#$frontier) {
        my ($x,$y) = split /,/, $points[$i];
        my $point = $frontier->[$i];
        $svg .= '<circle cx="' . $x . '" cy="' . $y . '" r="5" fill="#315c42"><title>cost='
            . $point->{cost} . '; risk=' . xml_escape($point->{probability}) . '</title></circle>';
        $svg .= '<text x="' . $x . '" y="265" text-anchor="middle" font-family="monospace" font-size="11">'
            . $point->{cost} . '</text>';
    }
    $svg .= '<text x="325" y="290" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#687467">repair cost</text>';
    return $svg . '</svg>';
}

1;
