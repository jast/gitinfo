# Provides a facility for creating temporary shortened links.
# Plugins call this to generate a shortened link; a control client can
# retrieve the long URL given the keyword from the shortened one.
use POSIX;

my %links = ();
my $id = 1;
my $chars = '023456789abcdefghkmnopqrstuvwxyz';
my $numchars = length($chars);

my $int_to_str = sub {
	my $i = shift;
	my $res = '';
	while ($i > 0) {
		$res = substr($chars, $i % $numchars, 1) . $res;
		$i = POSIX::floor($i/$numchars);
	}
	$res;
};

{
	functions => {
		make => sub {
			my $tag = $int_to_str->($id++);
			$links{$tag} = shift;
			return $BotIrc::config->{templink_baseurl} . $tag;
		},
	},
	control_commands => {
		'templink_get' => sub {
			my ($client, $data, @args) = @_;
			if (!exists $links{$args[0]}) {
				$client->put("error:notfound");
				return;
			}
			BotCtl::send($client, "ok", $links{$args[0]});
		},
	},
};
