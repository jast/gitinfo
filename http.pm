package BotHttp;
use Carp;
use common::sense;
use HTTP::Request;
use HTTP::Status;
use POE;

my %requests = ();
my $reqid = 1;

sub init() {
	$BotIrc::kernel->state('http_response', sub {
		my ($request_packet, $response_packet) = @_[ARG0, ARG1];
		my $request = $request_packet->[0];
		my $tag = $request_packet->[1];
		my $response = $response_packet->[0];
		croak("Received HTTP response for unknown tag '$tag'") if (!exists $requests{$tag});
		my $r = delete $requests{$tag};
		if (my $err = $response->header('X-PCCH-Errmsg')) {
			$r->{err_cb}($err, $response);
			return;
		}
		if (HTTP::Status::is_error($response->code)) {
			$r->{err_cb}($response->status_line, $response);
			return;
		}
		$r->{ok_cb}($response->decoded_content, $response);
	});
}

sub request($$$) {
	my ($req, $ok_cb, $err_cb) = @_;
	my $tag = "request$reqid";
	$reqid++;
	$requests{$tag} = {
		ok_cb	=> $ok_cb,
		err_cb	=> $err_cb,
	};
	$BotIrc::kernel->post('http', 'request', 'http_response', $req, $tag);
}

sub get($$$) {
	my ($url, $ok_cb, $err_cb) = @_;
	my $req = GET($url);
	request($req, $ok_cb, $err_cb);
}
