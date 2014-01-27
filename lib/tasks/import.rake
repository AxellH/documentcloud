# Initial DB import (Worker02):
# mysql -u root -p docviewer_prod < docviewer_prod-20101213.sql

namespace :import do


  desc "Create/Modify an organization with accounts read from file. File should not have header row and contain Fname, Lname, email, and admin columns."
  task :accounts, [:org_name, :org_slug, :csv, :lang] => :environment do | t,args |
    args.with_defaults(:lang=>'eng')

    Organization.transaction do
      begin

        organization = Organization.find_or_create_by_slug( args[:org_slug] )
        organization.demo = true
        organization.name = args[:org_name]
        organization.language = organization.document_language = args[:lang]
        organization.save!

        puts "Account ID,First Name,Last Name,Email,Password"

        CSV.foreach( args[:csv] ) do | fname, lname, email, is_admin |

          account = Account.new({ :email             => email.strip,
                                  :first_name        => fname.strip,
                                  :last_name         => lname.strip,
                                  :language          => args[:lang],
                                  :document_language => args[:lang] })

          pw = generate_password
          account.password = pw
          account.save!

          organization.add_member( account, is_admin ? Account::ADMINISTRATOR : Account::CONTRIBUTOR )

          puts [ account.id, account.first_name, account.last_name, account.email, pw ].join(",")
        end

      rescue Exception=>e
        STDERR.puts e
        raise ActiveRecord::Rollback
      end

    end

  end



  desc "Import the NYTimes' Document Viewer database"
  task :nyt => :environment do
    require 'mysql2'
    require 'tmpdir'
    require 'iconv'
    client = Mysql2::Client.new :host => 'localhost', :username => 'root', :database => 'docviewer_prod'
    docs   = client.query 'select * from documents where id in (16, 22, 92, 220) or (id > 542 and id < 546) order by id desc'
    docs.each do |doc|
      begin
        import_document(client, doc)
      rescue Exception => e
        puts e
        sleep 1
      end
    end
  end

end

def generate_password( len = 6 )
  charset = %w{ 2 3 4 6 7 9 A C D E F G H J K M N P Q R T V W X Y Z a c d e g h j k m n p q r v w x y z }
  (0...len).map{ charset.to_a[rand(charset.size)] }.join
end


# Import a single document (Mysql2 hash of attributes).
def import_document(client, record)

  ref = "#{record['id']} - #{record['title']}"
  puts "#{ref} -- starting..."

  asset_store = DC::Store::AssetStore.new
  access      = record['published_at'] ? DC::Access::PUBLIC : DC::Access::ORGANIZATION

  doc = Document.create({
    :organization_id  => 20,    # NYTimes
    :account_id       => 1159,  # newsdocs@nytimes.com
    :access           => DC::Access::PENDING,
    :title            => record['title'],
    :slug             => record['slug'],
    :source           => record['creator'].blank? ? nil : record['creator'],
    :description      => record['description'],
    :created_at       => record['created_at'],
    :updated_at       => record['updated_at'],
    :related_article  => record['story_url']
  })
  doc.remote_url = "http://documents.nytimes.com/#{record['slug']}"

  puts "#{ref} -- importing pages..."

  page_records = client.query "select * from pages where document_id = #{record['id']} order by page_number asc"
  pages        = []
  prev_page    = nil
  page_records.each do |page_record|
    text = Iconv.iconv('ascii//translit//ignore', 'utf-8', page_record['contents']).first
    # Some NYT docs have duplicate pages.
    next if prev_page && (prev_page.page_number == page_record['page_number'])
    pages.push prev_page = doc.pages.create({
      :page_number => page_record['page_number'],
      :text        => text,
      :access      => access
    })
  end
  puts "#{ref} -- #{pages.length} pages..."
  doc.page_count = pages.length

  if doc.page_count <= 0
    puts "#{ref} -- zero pages, aborting..."
    doc.destroy
    return
  end

  puts "#{ref} -- refreshing page map, extracting dates, indexing..."

  Page.refresh_page_map doc
  EntityDate.refresh doc
  doc.save!
  pages = doc.reload.pages
  Sunspot.index pages

  puts "#{ref} -- extracting entities from Calais, uploading text to S3..."
  DC::Import::EntityExtractor.new.extract(doc, doc.combined_page_text)
  doc.upload_text_assets(pages, access)
  sql = ["access = #{access}", "document_id = #{doc.id}"]
  Entity.update_all(*sql)
  EntityDate.update_all(*sql)

  puts "#{ref} -- importing sections..."

  sections = client.query "select * from chapters where document_id = #{record['id']} order by start_page asc"
  sections.each do |section_record|
    doc.sections.create({
      :title        => section_record['title'],
      :page_number  => section_record['start_page'],
      :access       => access
    })
  end

  puts "#{ref} -- importing notes..."

  notes = client.query "select * from notes where document_id = #{record['id']} order by page_number asc"
  notes.each do |nr|
    coords = [nr['y0'], nr['x1'], nr['y1'], nr['x0']].join(',')
    doc.annotations.create({
      :page_number  => nr['page_number'],
      :access       => DC::Access::PUBLIC,
      :title        => nr['title'],
      :content      => nr['description'],
      :location     => nr['layer_type'] == 'region' ? coords : nil
    })
  end

  puts "#{ref} -- grabbing PDF, uploading to S3..."

  Dir.mktmpdir do |tmpdir|
    pdf       = File.join(tmpdir, 'temp.pdf')
    image_dir = File.join(tmpdir, 'images')
    s3_url    = "http://s3.amazonaws.com/nytdocs/docs/#{record['id']}/#{record['id']}.pdf"
    puts `curl #{s3_url} > #{pdf}`
    asset_store.save_pdf(doc, pdf, access)

    puts "#{ref} -- processing images..."

    Docsplit.extract_images(pdf, :format => :gif, :size => Page::IMAGE_SIZES.values, :rolling => true, :output => image_dir)
    doc.page_count.times do |i|
      number = i + 1
      image  = "temp_#{number}.gif"
      asset_store.save_page_images(doc, number,
        {'normal'     => "#{image_dir}/700x/#{image}",
         'small'      => "#{image_dir}/180x/#{image}",
         'large'      => "#{image_dir}/1000x/#{image}",
         'small'      => "#{image_dir}/180x/#{image}",
         'thumbnail'  => "#{image_dir}/60x75!/#{image}"},
        access
      )
    end
  end

  doc.access = access
  doc.save
  puts "#{ref} -- finished."

end
