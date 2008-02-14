#!/usr/bin/env ruby

$:.unshift "#{File.dirname(__FILE__)}/lib"

require 'rubygems'
require 'csv'
require 'date'
require 'builder'
require 'mechanize'
require 'RMagick'

require 'name'
require 'configuration'

conf = Configuration.new

# Represents a period in the house of representatives
class HousePeriod
  attr_reader :from_date, :to_date, :from_why, :to_why
  attr_reader :division, :party, :name, :id
  
  @@id = 1
  
  def initialize(params)
    @id = @@id
    @@id = @@id + 1
    @from_date =  params[:from_date]
    @to_date =    params[:to_date]
    @from_why =   params[:from_why]
    @to_why =     params[:to_why]
    @division =   params[:division]
    @party =      params[:party]
    @name  =      params[:name]
    throw "Invalid keys" unless (params.keys -
      [:division, :party, :name, :from_date,
      :to_date, :from_why, :to_why]).empty?
  end
  
  def current?
    @to_why == "current_member"
  end
  
  def output(x)
    x.member(:id => "uk.org.publicwhip/member/#{@id}",
      :house => "commons", :title => @name.title, :firstname => @name.first,
      :lastname => @name.last, :constituency => @division, :party => @party,
      :fromdate => @from_date, :todate => @to_date, :fromwhy => @from_why, :towhy => @to_why)
  end
end

class Person
  attr_reader :name, :id
  attr_accessor :image_url
  
  @@id = 10001
  # Sizes of small thumbnail pictures of members
  @@THUMB_WIDTH = 44
  @@THUMB_HEIGHT = 59
  
  def initialize(name)
    @name = name
    @house_periods = []
    @id = @@id
    @@id = @@id + 1
  end
  
  # Adds a single continuous period when this person was in the house of representatives
  # Note that there might be several of these per person
  def add_house_period(params)
    @house_periods << HousePeriod.new(params.merge(:name => @name))
  end
  
  def display
    puts "Member: #{@name.informal_name}"
    @house_periods.each do |p|
      puts "  start: #{p.from_date} #{p.from_why}, end: #{p.to_date} #{p.to_why}"    
    end    
  end

  def output_person(x)
    x.person(:id => "uk.org.publicwhip/person/#{@id}", :latestname => @name.informal_name) do
      @house_periods.each do |p|
        if p.current?
          x.office(:id => "uk.org.publicwhip/member/#{p.id}", :current => "yes")
        else
          x.office(:id => "uk.org.publicwhip/member/#{p.id}")
        end
      end
    end
  end

  def output_house_periods(x)
    @house_periods.each {|p| p.output(x)}
  end 

  def image(width, height)
    if @image_url
      conf = Configuration.new
      res = Net::HTTP::Proxy(conf.proxy_host, conf.proxy_port).get_response(@image_url)
      begin
        image = Magick::Image.from_blob(res.body)[0]
        image.resize_to_fit(width, height)
      rescue
        puts "WARNING: Could not load image #{@image_url}"
      end
    end
  end
  
  def small_image
    image(@@THUMB_WIDTH, @@THUMB_HEIGHT)
  end
  
  def big_image
    image(@@THUMB_WIDTH * 2, @@THUMB_HEIGHT * 2)
  end
end

class People < Array
  def find_by_first_last_name(name)
    find_all do |p|
      p.name.first.downcase == name.first.downcase &&
        p.name.last.downcase == name.last.downcase
    end
  end

  def find_by_first_middle_last_name(name)
    find_all do |p|
      p.name.first.downcase == name.first.downcase &&
        p.name.middle.downcase == name.middle.downcase &&
        p.name.last.downcase == name.last.downcase
    end
  end

  # Find person with the given name. Returns nil if non found
  def find_by_name(name)
    throw "name: #{name} doesn't have last name" if name.last == ""
    r = find_by_first_last_name(name)
    if r.size == 0
      nil
    elsif r.size == 1
      r[0]
    else
      # Multiple results so use the middle name to narrow the search
      r = find_by_first_middle_last_name(name)
      if r.size == 0
        nil
      elsif r.size == 1
        r[0]
      else
        throw "More than one result for name: #{name.informal_name}"
      end
    end
  end
    
  def write_xml
    write_people_xml('pwdata/members/people.xml')
    write_images("pwdata/images/mps", "pwdata/images/mpsL")
    write_members_xml('pwdata/members/all-members.xml')
  end
  
  def write_members_xml(filename)
    xml = File.open(filename, 'w')
    x = Builder::XmlMarkup.new(:target => xml, :indent => 1)
    x.instruct!
    x.publicwhip do
      each{|p| p.output_house_periods(x)}
    end
    xml.close
  end
  
  def write_images(small_image_dir, large_image_dir)
    each do |p|
      p.small_image.write(small_image_dir + "/#{p.id}.jpg") if p.small_image
      p.big_image.write(large_image_dir + "/#{p.id}.jpg") if p.big_image
    end
  end
  
  def write_people_xml(filename)
    xml = File.open(filename, 'w')
    x = Builder::XmlMarkup.new(:target => xml, :indent => 1)
    x.instruct!
    x.publicwhip do
      each do |p|
        p.output_person(x)
      end  
    end
    xml.close
  end
end

class PeopleCSVReader
  def PeopleCSVReader.read(filename)
    # Read in csv file of members data

    data = CSV.readlines(filename)
    # Remove the first two elements
    data.shift
    data.shift

    i = 0
    people = People.new
    while i < data.size do
      name_text, division, state, start_date, start_reason, end_date, end_reason, party = data[i]

      name = Name.last_title_first(name_text)
      person = Person.new(name)

      start_date = parse_date(start_date)
      end_date = parse_end_date(end_date)
      start_reason = parse_start_reason(start_reason)
      person.add_house_period(:division => division, :party => party,
        :from_date => start_date, :to_date => end_date, :from_why => start_reason, :to_why => end_reason)
      i = i + 1
      # Process further start/end dates for this member
      while i < data.size && data[i][0] == name_text
        temp, division, state, start_date, start_reason, end_date, end_reason, party = data[i]
        start_date = parse_date(start_date)
        end_date = parse_end_date(end_date)
        start_reason = parse_start_reason(start_reason)
        person.add_house_period(:division => division, :party => party,
          :from_date => start_date, :to_date => end_date, :from_why => start_reason, :to_why => end_reason)
        i = i + 1
      end

      people << person
    end
    people
  end  

  private
  
  # text is in day.month.year form (all numbers)
  def PeopleCSVReader.parse_date(text)
    m = text.match(/([0-9]+).([0-9]+).([0-9]+)/)
    day = m[1].to_i
    month = m[2].to_i
    year = m[3].to_i
    Date.new(year, month, day)
  end

  def PeopleCSVReader.parse_end_date(text)
    # If no end_date is specified then the member is currently in parliament with a stupid end date
    if text == " " || text.nil?
      text = "31.12.9999"
    end
    parse_date(text)
  end

  def PeopleCSVReader.parse_start_reason(text)
    # If no start_reason is specified this means a general election
    if text == "" || text.nil?
      "general_election"
    else
      text
    end
  end
end

people = PeopleCSVReader.read("data/house_members.csv")

# Pick up photos of the current members

# Required to workaround long viewstates generated by .NET (whatever that means)
# See http://code.whytheluckystiff.net/hpricot/ticket/13
Hpricot.buffer_size = 262144

agent = WWW::Mechanize.new
agent.set_proxy(conf.proxy_host, conf.proxy_port)

def parse_person_page(sub_page, people)
  name = Name.last_title_first(sub_page.search("#txtTitle").inner_text.to_s[14..-1])
  content = sub_page.search('div#contentstart')
  
  # Grab image of member
  img_tag = content.search("img").first
  # If image is available
  if img_tag
    relative_image_url = img_tag.attributes['src']
    if relative_image_url != "images/top_btn.gif"
      image_url = sub_page.uri + URI.parse(relative_image_url)
    end
  end

  if image_url
    person = people.find_by_name(name)
    if person
      person.image_url = image_url
    else
      puts "WARNING: Skipping photo for #{name.full_name} because they don't exist in the list of people"
    end
  end
end

# Go through current members of house
agent.get(conf.current_members_url).links[29..-4].each do |link|
  sub_page = agent.click(link)
  parse_person_page(sub_page, people)
end
puts "Any skipped photos after here might be due to former politicians being senators"
# Go through former members of house and senate
agent.get(conf.former_members_url).links[29..-4].each do |link|
  sub_page = agent.click(link)
  parse_person_page(sub_page, people)
end

# Clear out old photos
system("rm -rf pwdata/images/mps/* pwdata/images/mpsL/*")

puts "Writing XML..."
people.write_people_xml('pwdata/members/people.xml')
people.write_members_xml('pwdata/members/all-members.xml')
puts "Writing people images..."
people.write_images("pwdata/images/mps", "pwdata/images/mpsL")

# And load up the database
system(conf.web_root + "/twfy/scripts/xml2db.pl --members --all --force")
image_dir = conf.web_root + "/twfy/www/docs/images"
system("rm -rf " + image_dir + "/mps/*.jpg " + image_dir + "/mpsL/*.jpg")
system("cp -R pwdata/images/* " + image_dir)

#people.each {|p| p.display}