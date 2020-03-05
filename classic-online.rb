# -*- coding: utf-8 -*-

require 'net/http'
require 'nokogiri'


def getDoc(url)
  url = "https://classic-online.ru" + url
  Nokogiri::HTML(Net::HTTP.get(URI(url)))
end

def dumpComposers(composers)
  composers.each do |c|
    puts "Dump: #{c.name}"
    open("#{c.id}.dump", "w") do |f|
      f.write(Marshal::dump(c))
    end
  end
end

def loadComposers(dir)
  Dir.chdir(dir) do 
    Dir.foreach(".").select {|p| /\.dump/ =~ p}.map do |p|
      puts p
      open(p, "r") do |f|
        Marshal::load(f.read)
      end
    end
  end
end

def dumpComposersToJson(composers)
  composers.each do |c|
    puts "Dump: #{c.name}"
    open("#{c.id}.json", "w") do |f|
      f.write(JSON.generate(c.toJson))
    end
  end
end

class Site
  @@Composers = nil
  @@Performers = nil

  # main entry point
  def self.loadSite
    self.getComposers.each do |composer|
      print("#{composer.name}\n")
      composer.compositions.each do |c|
        print("    composition: #{c.name}, performances.size: #{c.performances.size}\n")
      end
    end
  end

  def self.getComposers
    if @@Composers.nil? then
      @@Composers = self.getByLetter(:composers, Composer)
    end
    @@Composers
  end

  def self.getPerformers
    self.getByLetter(:performers, Performer)
  end

  def self.getByLetter(key, oclass)
    letters = extract_letters(getDoc("/"))
    letters[key].map do |l|
      self.extract_man_from_page(getDoc(l[:link]))
    end.flatten.map do |a|
      oclass.new(a[:name], a[:link])
    end
  end
  
  def self.extract_man_from_page(doc)
    doc.xpath('//table/tr').css("tr[class='even']").map do |x|
      node = x.xpath("td")[2].xpath("a")[0]
      {:name => node.text, :link => node['href']}
    end
  end

  def self.extract_letters_id(div_id, doc)
    doc.css("div[id='#{div_id}']").xpath("ul/li/a").map do |a|
      {:letter => a.text, :link => a['href']}
    end
  end
  
  def self.extract_letters(doc)
    { :composers => extract_letters_id('abc_left', doc),
      :performers => extract_letters_id('abc_right', doc) }
  end
end


class Composer
  private
  def download_compositions
    @compositions = Composer.extract_compositions(getDoc(@link)).map do |c|
      Composition.new(c[:name], c[:link])

    end
  end

  def _merge_compositions
    dict = {}
    compositions.each do |c|
      if dict.key?(c.id)
      then dict[c.id].add_name(c.name)
      else dict[c.id] = c
      end
    end
    @compositions = dict.values
  end        

  public
  def self.extract_compositions(doc)
    doc.css("div[class='productions_list']").xpath('table/tr/td/a').map do |a|
      {:name => a.text, :link => a['href']}
    end
  end

  def toJson
    {:name => name, :id => id, :link => link, :compositions => compositions.map {|c| c.toJson}}
  end

  def initialize(name, link)
    @name = name
    @link = link
    @id = /\/(\d+)$/.match(@link)[1].to_i
  end

  def compositions
    if @compositions.nil? then 
      download_compositions 
      _merge_compositions
    end
    @compositions
  end

  def setDownloaded!
    compositions.each do |comp|
      comp.performances.each do |p|
        p[:downloaded] = true
        
      end
    end
  end

  def totalSize
    total = 0
    performances.each do |p|
      total += p[:size].to_i
    end
    total.to_f / 2**30
  end

  def allLinks
    performances.map {|c| "classic-online.ru" + c[:upload_link]}
  end

  def saveAllLinks(file)
    open(file, "w") do |f|
      allLinks.each do |l|
        f.puts(l)
      end
    end
  end

  def performances
    compositions.map {|c| c.performances}.flatten
  end

  def name
    @name
  end

  def link
    @link
  end

  def compositions_ready?
    not (@compositions.nil?)
  end

  def id
    @id
  end

  def getUploadLinks
    cs = compositions.select do |c|
      not(c.performances.select{|p| not(p.key?(:upload_link))}.empty?)
    end
    if not(cs.empty?) then
      Net::HTTP.start("classic-online.ru", 80) do |http|
        compositions.each do |c|
          puts "#{name}: #{c.name}"
          c.getUploadLinks(http=http)
        end
      end
    else puts "#{name} - composer links uploaded"
    end

  end

  def evalSizes
    cs = compositions.select do |c|
      not(c.performances.select{|p| not(p.key?(:size))}.empty?)
    end
    if not(cs.empty?) then
      Net::HTTP.start("classic-online.ru", 80) do |http|
        compositions.each do |c|
          puts "#{name}: #{c.name}"
          c.evalSizes(http)
        end
      end
    else puts "#{name} - all sizes evaluated"
    end
  end

end    

class Performer
  def self.extract_performer(doc)
    extract_composers(doc)
  end

  def initialize(name, link)
    @name = name
    @link = link
    match = /\/ru\/(collective|performer)\/(\d+)$/.match(link)
    if not match.nil? then
      @type = if match[1] == "performer" then
                :performer
              else
                :collective
              end
      @id = match[2]
    else
      raise "Can't initialize Performer #{link}"
    end
  end

  def link
    @link
  end

  def name
    @name
  end

  def type
    @type
  end

  def id
    @id
  end
end

class Error
  @@errors = []
 
  def self.insert(e)
    @@errors.push(e)
  end
end


class Composition
  @@auth_key = nil
  @@pass = nil
  @@email = nil
  
  def self.setAuth(auth_key, pass, email)
    @@auth_key = auth_key
    @@pass = pass
    @@email = email
  end
  
  def self.authRequest(http, link)
    #  "/downloads/?file_id=69763"
    #  "/download.php?file_id=9359"
    link = link.gsub(/downloads\//, "download.php") 
    req = Net::HTTP::Get.new(link, {
                               "Cookie" => "auth_key=#{@@auth_key}; pass=#{@@pass}; email=#{@@email};" })
    
    res = http.request(req)
    res['location']
  end

  def self.extract_performances(doc)
    list = doc.css("table[class='archive']").css("div[class=performer_name]").map do |div|
      performers = div.xpath('a').map do |b|
        begin
          Performer.new(b.text, b['href'])
        rescue Exception => e
          Error.insert(e)
          nil
        end
      end
      
      text = div.next_element.next_element.to_s
      re = /\/archive\/\?file_id=(\d+)/
      f_id = re.match(text)

      { :performers => performers,
        :link => not(f_id.nil?) ? "/downloads/?file_id=" + f_id[1] : nil }

    end
  end
  
  private 
  def get_performances
    # TODO На данный момент разрушен алгоритм обхода страниц
    # UPDATE вроде на самом сайте отказались от идеи страниц
    Composition.extract_performances(getDoc(@link))
  end
  
  public
  def initialize(name, link)
    @name = name
    @other_names = []
    @link = link
    @id = /\/(\d+)$/.match(@link)[1].to_i
  end

  def toJson
    {:name => name, :link => @link, :id => id, :performances => performances}
  end

  def performances
    if @performances.nil? then
      @performances = get_performances
    else
      @performances.select {|p| p.class != Symbol}
    end
  end

  def performances_ready?
    not(@performances.nil?)
  end

  def name
    @name
  end

  def id
    @id
  end

  def link
    @link
  end

  def add_name(name)
    @other_names.push(name)
  end

  def getUploadLinks(http=nil)
    b = proc do |http|
      performances.select{|p| not(p.key?(:upload_link))}.each do |p|
        p[:upload_link] = p[:link].nil? ? nil : Composition.authRequest(http, p[:link])
      end
    end
    if http.nil? 
    then Net::HTTP.start("classic-online.ru", 80) {|http| b.call(http)}
    else b.call(http)
    end
  end

  def evalSizes(http)
    performances.select{|p| not(p.key?(:size))}.each do |p|
      if p[:upload_link].nil? then
        p[:size] = nil
      else
        res = http.head(p[:upload_link])
        p[:size] = res['content-length']
      end
    end
  end
end


def mark(hash, str)
  str1 = str.gsub(/^\./, "").gsub(/\n$/, "")
  if hash.key?(str1) then
    a = hash[str1]
    p = a[:performance]
    c = a[:composer]
    {:performance => p, :composer => c.name}
  else
    throw "error"
  end
end
