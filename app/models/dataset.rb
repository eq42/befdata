# This file contains the Dataset model, which maps the database table Datasets for the application.
# The Dataset title must be unique.

# Datasets contain the general metadata of a dataset. In addition, a dataset can contain:
# 1. Primary research data, as uploaded data values from a Dataworkbook,
#    where the information on the column is stored in Datacolumn instances
#    and the data values in Sheetcell instances. The original dataworkbook is stored as a Datafile
# 2. one or more asset (Freeformat) files.
#
# Datasets are taggable, that is, they can be linked to entries in the Tags table. This uses the is_taggable
# rails gem.
#
# Dataset provenance is managed using the ACL9 rails gem. Users can be given different roles in relation
# to a dataset (see User) and access to the dataset is controlled via the Role.
#
# Datasets can belong to one or more Project instances. They can also set free for download within their
# projects.
#
# Paperproposal instances contain one or more datasets. They are linked through
# the DatasetPaperproposal class.
#
# Highlighted methods:
# * approve_predefined_columns : after the initial upload of data a User can bulk approve columns,
#   without reviewing each column individually. The Datacolumn must be correctly described, in
#   that it must have a Datagroup and a Datatype.
require 'acl_patch'
class Dataset < ActiveRecord::Base
  include PgSearch
  include AclPatch
  acts_as_authorization_object :subject_class_name => 'User'
  acts_as_taggable

  has_attached_file :generated_spreadsheet,
    :path => ":rails_root/files/:id_generated-download.xls"

  has_many :upload_spreadsheets, :class_name => "Datafile", :order => 'id DESC', :dependent => :destroy
  has_one  :upload_spreadsheet,  :class_name => "Datafile", :order => 'id DESC'

  has_many :datacolumns, :dependent => :destroy, :order => "columnnr"
  has_many :sheetcells, :through => :datacolumns
  has_many :datagroups, :through => :datacolumns, :include => :categories
  has_many :freeformats, :as => :freeformattable, :dependent => :destroy

  has_many :dataset_downloads
  has_many :dataset_edits, :order => 'updated_at DESC', :dependent => :destroy
  has_one :unsubmitted_edit, :class_name => 'DatasetEdit', :conditions => ['submitted=?',false]

  has_and_belongs_to_many :projects
  has_many :dataset_paperproposals
  has_many :paperproposals, :through => :dataset_paperproposals

  validates :title, :presence => true, :uniqueness => true

  # validates_associated :upload_spreadsheet, :if => "upload_spreadsheet_id_changed?"

  before_validation(:load_metadata_from_spreadsheet, :on => :create)

  before_save :add_xls_extension_to_filename
  before_destroy :check_for_paperproposals

  pg_search_scope :search, against: {
    title: 'A',
    abstract: 'B',
    design: 'C',
    spatialextent: 'C',
    temporalextent: 'C',
    taxonomicextent: 'C',
    circumstances: 'C',
    dataanalysis: 'C',
  }, associated_against: {
    tags: {name: 'A'}
  },using: {
    tsearch: {
      dictionary: "english",
      prefix: true
    }
  }

  def add_xls_extension_to_filename
    if self.filename
      /\.xls$/.match(self.filename) ? self.filename : self.filename = "#{self.filename}.xls"
    end
  end
  def check_for_paperproposals
    if paperproposals.count > 0
      errors.add(:dataset,
        "can not be deleted while linked paperproposals exist [ids: #{paperproposals.map{|pp| pp.id}.join(", ")}]")
      return false
    end
  end

  def load_metadata_from_spreadsheet
    return if upload_spreadsheet.nil?

    book = dataworkbook
    self.attributes = book.general_metadata_hash
    self.set_start_and_end_dates_of_research(book)
    try_retrieving_projects_from_tag_list(book)
  end

  def try_retrieving_projects_from_tag_list(book)
    return if book.tag_list.blank?
    book.tag_list.split(",").each do |t|
      Project.find_by_converting_to_tag(t).each do |p|
        self.projects << p unless self.projects.include? p
      end
    end
  end

  def has_research_data?
    !upload_spreadsheet.blank?
  end

  def dataworkbook
    Dataworkbook.new(upload_spreadsheet)
  end

  def abstract_with_freeformats
    f_strings = self.freeformats.collect do |f|
      "File asset " + f.file_file_name + (f.description.blank? ? "" : (": " + f.description))
    end
    self.abstract + (f_strings.empty? ? "" : (" - " + f_strings.join(" - ")))
  end

  def set_start_and_end_dates_of_research(book)
    self.datemin = book.datemin
    self.datemax = book.datemax
  end
  def download_status
    return "outdated" if download_generation_status == 'finished' && download_generated_at < updated_at
    return download_generation_status
  end

  def cells_linked_to_values?
    self.sheetcells.exists?(["accepted_value IS NOT NULL OR accepted_value !='' OR category_id > 0"])
  end

  # During the import routine, we step through each of the data
  # columns using their header.
  def headers
    self.datacolumns.collect{|dc| dc.columnheader}
  end

  def finished_datacolumns
    datacolumns.select{|dc| dc.finished == true}
  end

  def datacolumns_with_approved_datagroup
    datacolumns.select{|dc| dc.datagroup_approved == true}
  end

  def datacolumns_with_approved_datatype
    datacolumns.select{|dc| dc.datatype_approved == true}
  end

  def predefined_columns
    # To be predefined, a column must have a datagroup and a datatype that is not 'unknown'.
    # The datagroup is created at import, so we only have to check for the datatype.
    # Furthermore, the datacolumn approval process must not have already started.
    datacolumns.select{|dc| Datatypehelper.find_by_name(dc.import_data_type).name != 'unknown' && dc.untouched?}
  end

  def approve_predefined_columns(approving_user)
    @columns_with_invalid_values = []
    predefined_columns.each do |column|
      column.datagroup_approved = true

      # Approve the datatype and store the values
      column.add_data_values(approving_user)
      column.datatype_approved = true

      # Check for invalid values
      column.finished = true if !column.has_invalid_values?
      @columns_with_invalid_values << column if column.has_invalid_values?

      # Save the column
      column.save
    end
  end

  def columns_with_invalid_values_after_approving_predefined
    #TODO this should be a proper method without relying on the state of this object
    raise "This method may be only called directly after executing 'approve_predefined_columns'" unless @columns_with_invalid_values
    @columns_with_invalid_values
  end

  def delete_imported_research_data
    datacolumns.destroy_all
  end

  def log_download(downloading_user)
    DatasetDownload.create(:user => downloading_user,
                          :dataset => self)
  end

  def number_of_observations
    #TODO use sql query finding max rownumber
    return 0 if datacolumns.empty?
    return datacolumns.first.sheetcells.count
  end

  def last_update
    dates = Array.new
      dates << self.updated_at
    dates << self.upload_spreadsheet.updated_at unless self.upload_spreadsheet.nil?
    dates += self.freeformats.collect {|x| x.updated_at}
    dates.max
  end

  def import_data
    begin
      self.update_attribute(:import_status, 'started importing')
      book = Dataworkbook.new(upload_spreadsheet)
      book.import_data
      self.update_attribute(:import_status, 'finished')
      self.enqueue_to_generate_download(:high)
    rescue Exception => e
      Rails.logger.error e.message
      Rails.logger.error e.backtrace.join("\n")
      self.update_attribute(:import_status, "error: #{e.message.first(248)}")
    end
  end

  def finished_import?
    self.import_status.to_s == 'finished' || !self.has_research_data?
  end

  def being_imported?   # TODO: this relies too much on the message
    return false unless self.has_research_data?
    ['queued', 'started importing'].include?(import_status) || import_status.starts_with?("processing")
  end

  def enqueue_to_generate_download(priority = :low)
    priority = 10 if priority.eql?(:low)
    priority = 0 if priority.eql?(:high)
    self.reload
    return unless finished_import?
    return if download_generation_status.eql?('queued')
    self.update_attribute(:download_generation_status, 'queued')
    self.delay(:priority => priority).generate_download
  end

  def generate_download
    self.update_attribute(:download_generation_status, 'started')

    self.generated_spreadsheet = ExcelExport.new(self).excel_temp_file
    self.generated_spreadsheet_file_name = title.gsub(/[^\w]/, '-')
    self.generated_spreadsheet_content_type = "application/xls"
    self.download_generated_at = Time.now + 1.second
    self.download_generation_status = 'finished'
    puts "=== Download generated for Dataset id: #{id} at #{Time.now}"
    save
  end

  def refresh_paperproposal_authors
    self.paperproposals.each {|pp| pp.update_datasets_providers}
  end
  
  def to_csv (separate_category_columns = false)
    # gather columns and values
    all_columns = []
    self.datacolumns.order("columnnr ASC").each do |dc|
      column = []
      category_column = []
      column[0] = dc.columnheader
      category_column[0] = "#{dc.columnheader}_Categories"

      dc.sheetcells.find_each do |sc|
        if !separate_category_columns || dc.import_data_type == 'category' || !(sc.datatype && sc.datatype.is_category? && sc.category)
          column[sc.row_number - 1] = sc.export_value
        else
          category_column[sc.row_number - 1] = sc.export_value
        end
      end
      all_columns << column
      all_columns << category_column if category_column.length > 1
    end

    # bring to same length to transpose
    max_length = all_columns.map{|c| c.length}.max
    all_columns.each{|c|   c[max_length-1] = nil unless c.length == max_length}
    all_columns  = all_columns.transpose

    CSV.generate do |csv|
      all_columns.each {|c| csv << c}
    end
  end

  def all_tags
    Dataset.tag_usage.select("tags.*").where("dataset_id =  #{self.id}").order("tags.name")
  end

  # This method returns similar datasets which are sorted by similarity in descending order
  def find_related_datasets
    tags = self.all_tags.map(&:id)
    return [] if tags.empty?
    datasets = Dataset.tag_usage.select("datasets.*,count(tags.*) as count").
                    where(["tags.id in (?) and datasets.id <> ?", tags, self.id]).
                    group("datasets.id").order("count(tags.*) desc")
    return(datasets)
  end

  def self.tag_counts
    Dataset.tag_usage.select("tags.*, count(datasets.id) as count").group("tags.id")
  end
  def self.tag_usage
    # Return a ActiveRecord::Relation object that can be reused by other methods
    Dataset.joins("
      join
      (
      select taggable_id as dataset_id, tag_id
      from taggings
      where taggable_type = 'Dataset'
      union
      select distinct d.dataset_id, g.tag_id
      from taggings g join datacolumns d
      on g.taggable_id = d.id
      where g.taggable_type = 'Datacolumn'
      ) c
      on datasets.id = c.dataset_id
      join tags
      on tags.id = c.tag_id
    ")
  end

  def self.joins_datafile_and_freeformats(workbook = nil)
    rel = self.joins("
      left join freeformats on freeformats.freeformattable_id = datasets.id AND freeformats.freeformattable_type='Dataset'
      left join datafiles on datafiles.dataset_id = datasets.id
    ").group('datasets.id')
    case workbook
      when true, 'true'
        rel = rel.having('count(datafiles.id) > 0')
      when false, 'false'
        rel = rel.having('count(datafiles.id) = 0')
    end
    return(rel)
  end

  # acl9 role related staff: different kinds of user
  def owners
    get_user_with_role(:owner)
  end

  def owners= (people)
    set_user_with_role(:owner, people)
  end

  # keep log of edits
  def create_or_use_unsubmitted_edit
    if !self.unsubmitted_edit.nil?
      self.unsubmitted_edit
    else
      self.dataset_edits.new
    end
  end

  def log_edit(string)
    unless self.unsubmitted_edit.nil? && (Time.now - 10.minutes) < self.created_at
      self.create_or_use_unsubmitted_edit.add_line!(string)
    end
  end

  def free_for?(user)
    return true if self.free_for_public
    if user && (self.free_for_members || self.free_within_projects && !(user.projects & self.projects).empty?)
      return true
    end
    false
  end

end
