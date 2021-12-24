#!/usr/bin/env perl
#
# flashtree.pl
# 2021 - John Bradley (userjack6880/systemanomaly)
#
# Available at: https://github.com/userjack6880/flashtree.pl
#
# flashtree.pl is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have recieved a copy fo the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.

use strict;
use warnings;
use DateTime;
use JSON;
use Device::BCM2835;
use Switch;
use Data::Dumper;
use LWP::UserAgent;
use LWP::Protocol::https;
use Time::HiRes qw(usleep);
use Curses;
use Net::Ping;

# create a ping object
our $ping = Net::Ping->new;

# and a pinger to return if we have 'net
sub conn_status() {
	return $main::ping->ping('45.33.100.239'); # this pings systemanomaly.com
}

# bearer_token
my $token = "";

# call init to test to see if library is installed
Device::BCM2835::init() || die "Could not init Device::BCM2835";

# initialize input/output
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_GPIO_P1_16, &Device::BCM2835::BCM2835_GPIO_FSEL_INPT); # top button
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_GPIO_P1_18, &Device::BCM2835::BCM2835_GPIO_FSEL_INPT); # bottom button

Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_GPIO_P1_11, &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP); # LED Set 1
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_V2_GPIO_P1_13, &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP); # LED Set 2
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_BPLUS_GPIO_J8_29, &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP); # LED Set 3
Device::BCM2835::gpio_fsel(&Device::BCM2835::RPI_BPLUS_GPIO_J8_31, &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP); # LED Top Light

# some subroutines so we don't have to type the awful stuff above anymore
sub gpio_output {
	my $pin = shift;
	my $value = shift;

	# this is gross, but I'm being lazy
	switch($pin) {
		case "hb"	{ Device::BCM2835::gpio_write(&Device::BCM2835::RPI_BPLUS_GPIO_J8_31, $value) }
		case 2		{ Device::BCM2835::gpio_write(&Device::BCM2835::RPI_BPLUS_GPIO_J8_29, $value) }
		case 1		{ Device::BCM2835::gpio_write(&Device::BCM2835::RPI_GPIO_P1_11, $value) }
		case 0		{ Device::BCM2835::gpio_write(&Device::BCM2835::RPI_V2_GPIO_P1_13, $value) }
		else	{ print "invalid output pin requested\n" }
	}
}

sub gpio_input {
	my $pin = shift;
	my $value = 0;

	# also gross
	switch($pin) {
		case "top"	{ $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_GPIO_P1_16) } # top button
		case "bottom"   { $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_GPIO_P1_18) } # bottom button
		case "hb"	{ $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_BPLUS_GPIO_J8_31) }
		case 2		{ $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_BPLUS_GPIO_J8_29) }
		case 1		{ $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_GPIO_P1_11) }
		case 0		{ $value = Device::BCM2835::gpio_lev(&Device::BCM2835::RPI_V2_GPIO_P1_13) }
		else		{ print "invalid input pin requested\n" }
	}

	return $value;	# when the buttons aren't pressed, it returns 1
}

# ncurses magic

sub init_disp {
	initscr;
	curs_set(0);
	my $win = Curses->new;

	$win->clear();

	$win->addstr(1,20,"*");
	$win->addstr(2,19,"/.\\");
	$win->addstr(3,18,"/..'\\");
	$win->addstr(4,18,"/'.'\\");
	$win->addstr(5,17,"/.''.'\\");
	$win->addstr(6,17,"/.'.'.\\");
	$win->addstr(7,16,"/'.''.'.\\");
	$win->addstr(8,16,"^^^[_]^^^");
	$win->addstr(9,17,"\\-----/");

	$win->addstr(3,13,"Merry Christmas!");
	$win->addstr(4,15,"Initializing");
	$win->refresh;
	return $win;
}

sub dinit_disp {
	endwin;
}

sub print_mode {
	my $win = shift;
	my $mode = shift;

	$win->move(4,0);
	$win->clrtoeol();
	if ( $mode == 0 ) { 
		$win->addstr(4,15,"Offline Mode");
		$win->move(5,0);
		$win->clrtoeol();	
		$win->addstr(5,17,"/.''.'\\");
		$win->move(10,0);
		$win->clrtoeol();	
	} else { $win->addstr(4,15,"Twitter Mode"); }
	$win->refresh;
}

sub print_tweets {
	my $win = shift;
	my $tweets = shift;

	$win->move(5,0);
	$win->clrtoeol();	
	$win->addstr(5,17,"/.''.'\\");
	my $size = length($tweets);
	$win->addstr(5,15-$size, "$tweets in the last hour");
	$win->refresh;
}

sub print_date_fetch {
	my $win = shift;
	my $date = DateTime->now( time_zone => 'local' )->strftime('%d %B %Y, %H:%M');

	$win->move(10,0);
	$win->clrtoeol();	
	$win->addstr(10,1,"Fetched $date");
	$win->refresh;
}

# heartbeat
sub heartbeat {
	my $hbval = gpio_input("hb") == 0 ? 1 : 0;
	gpio_output("hb",$hbval);
}

sub initialize {
	for ( my $i = 0; $i < 2; $i++ ) {
		gpio_output("hb",1);
		usleep(50000);
		gpio_output(0,1);
		usleep(50000);
		gpio_output(1,1);
		usleep(50000);
		gpio_output(2,1);
		usleep(100000);
		gpio_output("hb",0);
		usleep(50000);
		gpio_output(0,0);
		usleep(50000);
		gpio_output(1,0);
		usleep(50000);
		gpio_output(2,0);
		usleep(50000);
	}
}

sub flash_rand {
	my $randpin = int(rand(3));
	gpio_input($randpin) == 0 ? gpio_output($randpin,1) : gpio_output($randpin,0);

}

# this randomly turns on or off a set of lights, then inverts the heartbeat
sub random_set {
	heartbeat();
	usleep(500000);
	heartbeat();
	flash_rand();
	usleep(500000);


	
	if ( $main::cycle == 10 ) {
		# before we even bother with tweet mode, we need to revert to regular mode if there is no net
		if ( conn_status() == 1 ) {
			$main::win->move(4,1);
			$main::win->clrtoeol();
			$main::win->addstr(4,1,"Switching to Online Mode!");
			$main::win->refresh();
			sleep(1);
			$main::mode = 1;
			print_mode($main::win, $main::mode);
			return;
		}
	}

	$main::cycle == 10 ? $main::cycle = 0 : $main::cycle++;		# this should occur every 10 seconds or so
}

# now turn off the lights - seems to turn some pins on by default
sub turn_off {
	gpio_output("hb",0);
	gpio_output(0,0);
	gpio_output(1,0);
	gpio_output(2,0);
}

turn_off();

# meat of this code - asking twitter for a number of tweets and then doing some math and determine how quickly we need to flash
sub tweet_set {
	my $speed = shift;
	my $cycle = shift;

	# before we even bother with tweet mode, we need to revert to regular mode if there is no net
	if ( conn_status() == 0 ) {
		$main::win->move(4,1);
		$main::win->clrtoeol();
		$main::win->addstr(4,1,"Could not connect!");
		$main::win->refresh();
		sleep(1);
		$main::mode = 0;
		print_mode($main::win, $main::mode);
		return;
	}

	# on cycle 0, we do these things
	if ( $cycle == 0 ) {

		# get the date/time for the hour prior to now, ending with this current hour
		my $start_date = DateTime->now( time_zone => 'UTC' )->subtract( hours => 1 )->strftime('%Y-%m-%dT%H:%M:00.000Z');
		my $end_date = DateTime->now( time_zone => 'UTC' )->strftime('%Y-%m-%dT%H:%M:00.000Z');

		print_date_fetch($main::win);

		# let's get a number from twitter
		my $ua = LWP::UserAgent->new(send_te => 0);
	       	my $req = HTTP::Request->new(
			GET => "https://api.twitter.com/2/tweets/counts/recent?query=%23Christmas&start_time=$start_date&end_time=$end_date",
			[
				'Authorization'	=>	"Bearer $token",
				'Content-Type'	=>	"application/json"
			]
		);

		my $res = $ua->request($req);
		my $twitter_data = decode_json($res->decoded_content);

		my $tweet_count = $twitter_data->{meta}{total_tweet_count} // 0;
		print_tweets($main::win, $tweet_count);		

		# calculations to figure how how quickly to flash	
		my $divisions = $tweet_count/2000;	# divide threshold by 10 and replace the number to adjust the speed
		if ( $divisions > 0 ) {		#otherwise this will break
			$speed = 10000000/$divisions;
		}
		else {
			$speed = -1;
			$cycle = 90; # this should force it to try again
		}
		$main::speed = $speed;

	}
	my $elapsed = 0;
	my $heartbeat_timeout = 1000000;
	heartbeat();

	while ($elapsed < 10000000) {
		# because this cycles more than 1s, let's check the button now
		button_check();

		last if ( $main::mode == '0' );

		# if the heartbeat timeout drops below 0, perform a heartbeat operation and reset timeout
		if ( $heartbeat_timeout <= 0 ) {
			heartbeat();
			$heartbeat_timeout = 1000000;
		}

		if ( $speed == -1 ) {
			sleep(1);
			$elapsed = $elapsed+1000000;
			$heartbeat_timeout = 0;
		}
		# for times less than 1 second per flash
		elsif ( $speed < 1000000 ) {
			flash_rand();
			usleep( $speed );
			$elapsed = $elapsed+$speed;
			$heartbeat_timeout = $heartbeat_timeout-$speed;
		}
		# if we hit the magic 1 second per flash number
		elsif ( $speed == 1000000 ) {
			flash_rand();
			sleep(1);
			$elapsed = $elapsed+$speed;
			$heartbeat_timeout = 0;
		}
		# and for times greater than 1 second per flash
		else {
			flash_rand();
			usleep($heartbeat_timeout);		# sleep for remainder of heartbeat timeout
			heartbeat();
			usleep($speed-$heartbeat_timeout);	# sleeps for the remainder of time
			$elapsed = $elapsed+$speed;
			$heartbeat_timeout = $heartbeat_timeout-$speed;
		}
	}
	$cycle == 90 ? $main::cycle = 0 : $main::cycle++;		# this should occur every 15 minutes or so
}

sub button_check {
	# if both are being held, kill the script
	if ( gpio_input("top") == '0' && gpio_input("bottom") == '0') {
		$main::win->clear();
		$main::win->addstr(2,1,"Goodbye");
		sleep(1);
		turn_off();
		dinit_disp();
		exit;
	}

	# check if the top is being held
	if ( gpio_input("top") == '0' ) {
		$main::mode = 0;
		$main::cycle = 0;

		# announce the mode
		print_mode($main::win, $main::mode);
	}

	# check if the bottom is being held
	if ( gpio_input("bottom") == '0' ) {
		$main::mode = 1;
		$main::cycle = 0;

		# announce the mode
		print_mode($main::win, $main::mode);
	}
}

# initial conditions
our $mode = 0;
our $cycle = 0;
our $speed = 10000000;

$mode = 1 if ( conn_status() == 1 );

our $win = init_disp();
initialize();
print_mode($win, $mode);

# main code
while (1) {
	button_check();
	random_set() if ( $mode == '0' );
	tweet_set($speed, $cycle) if ( $mode == '1' );
}
