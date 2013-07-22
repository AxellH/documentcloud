require 'cgi'

class RemoteUrl < ActiveRecord::Base

  self.establish_connection( DC::ANALYTICS_DB )

  DOCUMENT_CLOUD_URL = /^https?:\/\/(www\.)?documentcloud.org/

  scope :aggregated, -> {
    select( 'sum(hits) AS hits, document_id, url' )
    .group( 'document_id, url' )
  }

 scope :by_document, -> {
    select( 'sum(hits) AS hits, document_id' )
    .group( 'document_id' )
    .having( 'document_id is not NULL' )
  }

  scope :by_search_query, -> {
    select('sum(hits) AS hits, search_query, url')
    .group( 'search_query, url' )
    .having( 'search_query is not NULL' )
  }

  scope :by_note, -> {
    select( 'sum(hits) AS hits, note_id, url' )
    .group( 'note_id, url' )
    .having( 'note_id is not NULL' )
  }

  def self.record_hits_on_document(doc_id, url, hits)
    url = url.mb_chars[0...255].to_s
    row = self.find_or_create_by_document_id_and_url_and_date_recorded(doc_id, url, Time.now.utc.to_date)
    row.update_attributes :hits => row.hits + hits
    
    # Increment the document's total hits.
    doc = Document.find_by_id(doc_id)
    doc.update_attributes(:hit_count => doc.hit_count + hits) if doc
  end

  def self.record_hits_on_search(query, url, hits)
    url   = url.mb_chars[0...255].to_s
    query = CGI::unescape(query)
    row   = self.find_or_create_by_search_query_and_url_and_date_recorded(query, url, Time.now.utc.to_date)
    row.update_attributes :hits => row.hits + hits
  end

  def self.record_hits_on_note(note_id, url, hits)
    url = url.mb_chars[0...255].to_s
    row = self.find_or_create_by_note_id_and_url_and_date_recorded(note_id, url, Time.now.utc.to_date)
    row.update_attributes :hits => row.hits + hits
  end

  # Using the recorded remote URL hits, correctly set detected remote urls
  # for all listed document ids. This method is only ever run within a
  # background job.
  def self.populate_detected_document_ids(doc_ids)
    urls = self.aggregated.all(:conditions => {:document_id => doc_ids})
    top  = urls.inject({}) do |memo, url|
      if DOCUMENT_CLOUD_URL =~ url.url
        memo
      else
        id = url.document_id
        memo[id] = url if !memo[id] || memo[id].hits < url.hits
        memo
      end
    end
    Document.find_each(:conditions => {:id => top.keys}) do |doc|
      doc.detected_remote_url = top[doc.id].url
      doc.save if doc.changed?
    end
  end

  def self.top_documents(days=7, options={})
    hit_documents = self.by_document.all({
      :conditions => ['date_recorded > ?', days.days.ago],
      :having => ['sum(hits) > 0'],
      :order => 'hits desc'
    }.merge(options))
    docs = Document.find_all_by_id(hit_documents.map {|u| u.document_id }).inject({}) do |memo, doc|
      memo[doc.id] = doc
      memo
    end
    hit_documents.select {|url| !!docs[url.document_id] }.map do |url|
      url_attrs = url.attributes
      url_attrs[:url] = docs[url.document_id].published_url
      url_attrs[:id] = "#{url.document_id}:#{url_attrs[:url]}"
      first_hit = RemoteUrl.first(:select => 'created_at',
                                  :conditions => {:document_id => url['document_id']},
                                  :order => 'created_at ASC')
      url_attrs[:first_recorded_date] = first_hit[:created_at].strftime "%a %b %d, %Y"
      docs[url.document_id].admin_attributes.merge(url_attrs)
    end
  end
  
  def self.top_searches(days=7, options={})
    hit_searches = self.by_search_query.all({
      :conditions => ['date_recorded > ?', days.days.ago],
      :having => ['sum(hits) > 0'],
      :order => 'hits desc'
    }.merge(options))
    hit_searches.map do |query|
      query_attrs = query.attributes
      first_hit = RemoteUrl.first(:select => 'created_at',
                                  :conditions => {:search_query => query.search_query},
                                  :order => 'created_at ASC')
      query_attrs[:first_recorded_date] = first_hit[:created_at].strftime "%a %b %d, %Y"
      query_attrs
    end
  end
  
  def self.top_notes(days=7, options={})
    hit_notes = self.by_note.all({
      :conditions => ['date_recorded > ?', days.days.ago],
      :having => ['sum(hits) > 0'],
      :order => 'hits desc'
    }.merge(options))
    notes = Annotation.find_all_by_id(hit_notes.map {|n| n.note_id }).inject({}) do |memo, note|
      memo[note.id] = note.canonical.merge({:document_id => note.document_id})
      memo
    end
    docs = Document.find_all_by_id(notes.map {|id, n| n[:document_id] }).inject({}) do |memo, doc|
      memo[doc.id] = doc
      memo
    end
    hit_notes.select {|note| !!notes[note.note_id] }.map do |note|
      note_attrs = note.attributes
      note_attrs.delete :id
      note_attrs[:document] = docs[notes[note.note_id][:document_id]]
      first_hit = RemoteUrl.first(:select => 'created_at',
                                  :conditions => {:note_id => note.note_id},
                                  :order => 'created_at ASC')
      note_attrs[:first_recorded_date] = first_hit[:created_at].strftime "%a %b %d, %Y"
      notes[note.note_id].merge(note_attrs)
    end
  end

end
