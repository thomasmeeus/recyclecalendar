require 'sinatra'
require 'sinatra/multi_route'
require 'sinatra/logger'
require 'json'
require 'dotenv/load'
require 'curb'
require 'icalendar'
require 'date'
require 'active_support/core_ext' 
require 'mysql2'
require 'sequel'

include ERB::Util

##############################
# Initialize
# Read app config files etc

# begin sinatra configure block
configure do
  # enable sessions
  use Rack::Session::Pool

  # enable logging
  set :root, Dir.pwd
  set :logger, Logger.new(STDERR)

  # bind
  set :bind, '0.0.0.0'

  # populate appconfig hash via environment vars or read from the .env config file
  $appconfig = Hash.new

  # Mysql backend
  #
  $appconfig['mysql_host']     = ENV['MYSQL_HOST']     || nil
  $appconfig['mysql_database'] = ENV['MYSQL_DATABASE'] || nil
  $appconfig['mysql_user']     = ENV['MYSQL_USER']     || nil
  $appconfig['mysql_password'] = ENV['MYSQL_PASSWORD'] || nil

  #
  # Global Variables
  #

  # Recycle App
  $appconfig['recycleapp_base_url']  = ENV['RECYCLEAPP_BASE_URL']  || nil
  $appconfig['recycleapp_token_url'] = ENV['RECYCLEAPP_TOKEN_URL'] || nil
 
  # 2021-01-29: the recycleapp_x_secret value changed
  # the RECYCLEAPP_X_SECRET variable is now automatically retrieved
  # from the recycleapp.be main javascript file
  #
  # $appconfig['recycleapp_x_secret']  = ENV['RECYCLEAPP_X_SECRET']  || nil

  # Vlaanderen API
  $appconfig['vlaanderen_api_token'] = ENV['VLAANDEREN_API_TOKEN'] || nil
  $appconfig['vlaanderen_api_url']   = ENV['VLAANDEREN_API_URL']   || nil

  # Notifications
  $appconfig['notifications'] = ENV['NOTIFICATIONS']  || nil

  # Timezone
  $appconfig['timezone'] = ENV['TIMEZONE']  || nil

  # Postal Code Matrix - Use correct backend for streetname lookups
  # Currently only addresses in Flanders can be resolved correctly
  # 
  # BE.BRUSSELS.BRIC.ADM.STR
  # 1000 - 1999 Brussel, Halle-Vilvoorde en Waals-Brabant
  #
  # https://data.vlaanderen.be/id/straatnaam
  # 2000 - 2999 provincie Antwerpen
  # 3000 - 3999 arrondissement Leuven en provincie Limburg
  # 8000 - 8999 West-Vlaanderen
  # 9000 - 9999 Oost-Vlaanderen
  #
  # geodata.wallonie.be/id/streetname
  # 4000 - 4999 provincie Luik
  # 5000 - 5999 provincie Namen
  # 6000 - 6999 Henegouwen (Oost) en Luxemburg (provincie)
  # 7000 - 7999 Henegouwen (West)
  
  $postalcode_matrix = Hash.new
  $postalcode_matrix[(1000..1999)] = "BE.BRUSSELS.BRIC.ADM.STR"
  $postalcode_matrix[(2000..3999)] = "https://data.vlaanderen.be/id/straatnaam"
  $postalcode_matrix[(4000..7999)] = "geodata.wallonie.be/id/streetname"
  $postalcode_matrix[(8000..9999)] = "https://data.vlaanderen.be/id/straatnaam"

end

############################
# Start Function Definitions
#

helpers do
  # this is the main function
  # it pulls a pickup calendar from recycleapp.be based on postalcode, streetname and housenumber
  #
  def get_pickup_dates(postalcode,streetname,housenumber)

    # construct the url we need to call to get all pickup events from recycleapp.be
    #
    # example: https://recycleapp.be/api/app/v1/collections?zipcodeId=1234-24043&streetId=https://data.vlaanderen.be/id/straatnaam-5678&houseNumber=100&fromDate=2020-11-01&untilDate=2020-12-31&size=100
    recycleapp_url = construct_recycleapp_url(postalcode,streetname,housenumber)

    # get a token to gain access to recycleapp.be
    recycleapp_token = fetch_recycleapp_token($appconfig['recycleapp_token_url'])

    # fetch the actual pickup events
    pickup_dates = Curl.get(recycleapp_url) do |curl|
      curl.headers["Accept"]          = "application/json, text/plain, */*"
      curl.headers["Authorization"]   = recycleapp_token
      curl.headers["x-consumer"]      = "recycleapp.be"
    end

    # convert the received events into a Ruby data structure
    pickup_events_json = JSON.parse(pickup_dates.body_str)

    # fetch timestamps,fractions and color from pickup_events_json as that is all we need
    pickup_events_simple = Array.new
    pickup_events_json['items'].each do |item|
      if item['type'] == "collection"
        pickup = Hash.new
        pickup['timestamp']          = item['timestamp']
        pickup['formattedtimestamp'] = Date.parse(item['timestamp']).strftime("%A %d-%m-%Y")
        pickup['fraction']           = item['fraction']['name']['nl'] 
        pickup['color']              = item['fraction']['color']
        pickup_events_simple.push(pickup)
      end
    end

    return pickup_events_simple
  end

  # a token is required to get access to recycleapp.be
  #
  # the value for recycleapp_x_secret, which is required to fetch the token, is hidden inside the main javascript file
  # we do a dirty scrape to fetch the filename of the main javascript
  # then we search for the secret string inside the javascript file
  # and use that string to retrieve the token
  #
  # This is dirty. Sorry.
  #
  def fetch_recycleapp_token(token_url)
    # search for the main.*.chunk.js filename inside the html returned by https://recycleapp.be
    recycleapp_index_html = Curl.get("https://recycleapp.be")
    main_js_filename      = recycleapp_index_html.body_str[/(?:src="| )(\/static\/js\/main\..*?\.chunk\.js)/,1]

    # in the main.*.js filename just scraped from the html,
    # search for the secret string we need to use as recycleapp_x_secret
    recycleapp_main_js_script = Curl.get("https://recycleapp.be#{main_js_filename}")
    recycleapp_x_secret       = recycleapp_main_js_script.body_str[/var n\=\"(.*?)\",c\=\"\/api\/v1\/assets\/\"/,1]

    # retrieve an access token on https://recycleapp.be/api/app/v1/access-token
    # using the scraped recycleapp_x_secret
    recycleapp_token_json = Curl.get(token_url) do |curl|
      curl.headers["Accept"]     = "application/json, text/plain, */*"
      curl.headers["x-consumer"] = "recycleapp.be"
      curl.headers["x-secret"]   = recycleapp_x_secret
    end

    recycleapp_token = JSON.parse(recycleapp_token_json.body_str)
    return recycleapp_token['accessToken']
  end

  # generate the url we will pull all pickup events from
  # 
  def construct_recycleapp_url(postalcode,streetname,housenumber)
    recycleapp_base_url = $appconfig['recycleapp_base_url']

    # lookup id's for streetame and gemeentenaam (municipality)
    @zipcodeid_streetnameid_gemeentenaam = fetch_zipcodeid_streetnameid_gemeentenaam(postalcode,streetname,housenumber)

    zipcodeid    = @zipcodeid_streetnameid_gemeentenaam['zipcodeid']
    streetnameid = @zipcodeid_streetnameid_gemeentenaam['streetnameid']

    # Fromdate is first day of the month. Earliest date with events in calendar
    @fromdate = Date.today.beginning_of_month.strftime("%F")

    # Untildate is last day of this year. Last date with events in calendar
    # Unless month is december, then search for events next year
    thismonth = Date.today.strftime("%m")
    if thismonth == "12"
      @untildate = Date.today.next_month.end_of_year.strftime("%F")
    else
      @untildate = Date.today.end_of_year.strftime("%F")
    end

    # set the correct backend for the streetname
    $postalcode_matrix.each do |postalcoderange,backend|
      if postalcoderange.include? postalcode.to_i
        # example: https://recycleapp.be/api/app/v1/collections?zipcodeId=1234-24043&streetId=https://data.vlaanderen.be/id/straatnaam-5678&houseNumber=100&fromDate=2020-11-01&untilDate=2020-12-31&size=100
        recycleapp_url = recycleapp_base_url + "?zipcodeId=" + postalcode + "-" + zipcodeid + "&streetId=" + backend + "-" + streetnameid + "&houseNumber=" + housenumber + "&fromDate=" + @fromdate + "&untilDate=" + @untildate + "&size=100"
        return recycleapp_url
      end
    end
  end

  # consult api.basisregisters.vlaanderen.be to retrieve objectId's for postalcode and streetname
  # these id's are required to construct the recycleapp_url
  # we pull in 'gemeentenaam' (municipality) only to print a proper address in the HTML frontend
  #
  def fetch_zipcodeid_streetnameid_gemeentenaam(postalcode,streetname,housenumber)
    # example: https://api.basisregisters.vlaanderen.be/v1/adresmatch?postcode=1234&straatnaam=hoofdstraat
    vlaanderen_api_adresmatch   = Curl.get($appconfig['vlaanderen_api_url'] + "adresmatch?postcode=" + postalcode + "&straatnaam=" + streetname) do |curl|
      curl.headers["Accept"]    = "application/json, text/plain, */*"
      curl.headers["x-api-key"] = $appconfig['vlaanderen_api_token']
    end

    # fetch api result and http status code
    vlaanderen_api_adresmatch_json            = JSON.parse(vlaanderen_api_adresmatch.body_str)
    vlaanderen_api_adresmatch_http_statuscode = vlaanderen_api_adresmatch.status

    # error handling - check if a valid result was retrieved from the api
    if vlaanderen_api_adresmatch_http_statuscode.include? "200"
      # if no warnings are present, we found a valid address
      if vlaanderen_api_adresmatch_json['warnings'].empty?
        vlaanderen_adresmatch = Hash.new
        vlaanderen_adresmatch['zipcodeid']    = vlaanderen_api_adresmatch_json['adresMatches'][0]['gemeente']['objectId']
        vlaanderen_adresmatch['streetnameid'] = vlaanderen_api_adresmatch_json['adresMatches'][0]['straatnaam']['objectId']
        vlaanderen_adresmatch['gemeentenaam'] = vlaanderen_api_adresmatch_json['adresMatches'][0]['gemeente']['gemeentenaam']['geografischeNaam']['spelling']

        # log address retrieval to database
        add_record_to_database(postalcode,streetname,housenumber,vlaanderen_api_adresmatch_http_statuscode,"no warnings")

        return vlaanderen_adresmatch
      else
        # the api returned a http 200 and some warning
        @error_content = vlaanderen_api_adresmatch_json['warnings'][0]['message']

        # log address retrieval to database
        add_record_to_database(postalcode,streetname,housenumber,vlaanderen_api_adresmatch_http_statuscode,@error_content)

        halt erb :ics
      end
    else
      # the api did not return a http 200. fatal.
      @error_content = "De zoekopdracht kon niet correct worden afgehandeld. HTTP status #{vlaanderen_api_adresmatch_http_statuscode}."

      # log address retrieval to database
      add_record_to_database(postalcode,streetname,housenumber,vlaanderen_api_adresmatch_http_statuscode,@error_content)

      halt erb :ics
    end
  end

  # log all address lookups to the database
  #
  def add_record_to_database(postalcode,streetname,housenumber,http_status,api_warning)
    # connect to the database
    $DB = Sequel.connect(
            adapter:  'mysql2',
            test:     true,
            user:     $appconfig['mysql_user'],
            password: $appconfig['mysql_password'],
            host:     $appconfig['mysql_host'],
            port:     $appconfig['mysql_port'],
            database: $appconfig['mysql_database'])

    # create addresses table if it doesn't exist
    unless $DB.table_exists?(:addresses)
      $DB.create_table :addresses do
        primary_key :id
        column :created, 'timestamp'
        column :postalcode, Integer
        column :streetname, String
        column :housenumber, Integer
        column :http_status, String
        column :api_warning, String
        column :format, String
      end
    end

    # see how we were called (webinterface or ical program)
    format = String.new
    if params['getpickups']
      format = "web"
    elsif params['format']
      format = "ics"
    else
      format = "undefined"
    end

    # insert a new record
    table = $DB[:addresses]
    table.insert(
      postalcode:  postalcode,
      streetname:  streetname,
      housenumber: housenumber,
      http_status: http_status,
      api_warning: api_warning,
      format:      format)

    # clean up the database connection
    $DB.disconnect
  end

  # create an ICS object based on the events we pulled from recycleapp.be
  #
  def generate_ics(events,timezone,notifications)
    # create calendar object
    cal = Icalendar::Calendar.new

    # set calendar timezone
    cal.timezone do |t|
      t.tzid = timezone
    end

    # populate calendar with events
    events.each do |pickup_event|
      dt = Date.parse(pickup_event['timestamp'])
      event = Icalendar::Event.new
      event.dtstart = Icalendar::Values::Date.new(dt)
      event.dtend   = Icalendar::Values::Date.new(dt + 1)
      event.summary = pickup_event['fraction']
      event.transp = 'TRANSPARENT'

      # if required, enable notifications: one day up front
      if notifications == 'true' or notifications == '1'
        event.alarm do |a|
          a.summary = pickup_event['fraction']
          a.trigger = "-P1DT0H0M0S" # 1 day before
        end
      end

      # add the new event to the calendar object
      cal.add_event(event)
    end 

    ical_string = cal.to_ical
    return ical_string
  end
end

#
# End function definitions
##########################

#######################
# Start URI Definitions
#

# info
route :get, '/info' do
  erb :info
end

# main page
route :get, :post, '/' do
  postalcode    = params['postalcode']    || $appconfig['postalcode']
  streetname    = params['streetname']    || $appconfig['streetname']
  housenumber   = params['housenumber']   || $appconfig['housenumber']
  notifications = params['notifications'] || $appconfig['notifications']
  timezone      = params['timezone']      || $appconfig['timezone']

  # check if a valid request comes in
  if params['getpickups'] or params['format'] == 'ics' or (postalcode and streetname and housenumber)
    # get list of pickups
    @pickup_events = get_pickup_dates(postalcode,streetname,housenumber)

    # set ics formatted url
    @ics_formatted_url = "#{request.scheme}://#{request.host}/?postalcode=#{postalcode}&streetname=#{streetname}&housenumber=#{housenumber}&format=ics"
    @ics_formatted_url_with_notifications = "#{request.scheme}://#{request.host}/?postalcode=#{postalcode}&streetname=#{streetname}&housenumber=#{housenumber}&format=ics&notifications=true"

    # generate a hash with info to display in the :ics template
    @pickupinfo = Hash.new
    @pickupinfo['postalcode']   = postalcode 
    @pickupinfo['streetname']   = streetname 
    @pickupinfo['housenumber']  = housenumber 
    @pickupinfo['gemeentenaam'] = @zipcodeid_streetnameid_gemeentenaam['gemeentenaam']
    @pickupinfo['fromdate']     = @fromdate
    @pickupinfo['untildate']    = @untildate

    if params['format'] == 'ics'
      # render ICS format and halt
      halt generate_ics(@pickup_events,timezone,notifications)
    else
      # or render html and halt
      halt erb :ics
    end
  end

  # if no valid request came in, display default homepage
  erb :ics
end
