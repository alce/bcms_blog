class Blog < ActiveRecord::Base
  acts_as_content_block
  has_many :posts, :class_name => "BlogPost", :conditions => { :published => true }, :order => "published_at desc"

  has_many :blog_group_memberships
  has_many :groups, :through => :blog_group_memberships

  validates_presence_of :name
  validates_uniqueness_of :name

  named_scope :editable_by, lambda { |user|
    if user.able_to?(:administrate)
      { }
    else
      { :include => :groups, :conditions => ["groups.id IN (?)", user.group_ids.join(",")] }
    end
  }

  def self.default_template
    template_file = ActionController::Base.view_paths.map do |vp|
      path = vp.to_s.first == "/" ? vp.to_s : File.join(Rails.root, vp.to_s)
      File.join(path, "cms/blogs/render.html.erb")
    end.detect{|f| File.exists? f }
    template_file ? open(template_file){|f| f.read } : ""
  end

  def self.posts_finder(finder, options)
    if options[:tags]
      finder = finder.tagged_with(options[:tags])
    end
    if options[:exclude_tags]
      finder = finder.not_tagged_with(options[:exclude_tags])
    end
    if options[:category] || options[:category_id]
      category_type = CategoryType.named("Blog Post").first
      category = category_type.categories.named(options[:category]).first if options[:category]
      category = category_type.categories. find(options[:category_id])    if options[:category_id]
      finder = finder.in_category(category)
    end
    finder
  end

  def render
    @blog = self
    finder = @blog.posts.published
    finder = Blog.posts_finder(finder, params)

    if params[:year] && params[:month] && params[:day]
      @date = Date.new(params[:year].to_i, params[:month].to_i, params[:day].to_i)
      finder = posts.published_between(@date, @date + 1.day)
    elsif params[:year] && params[:month]
      @date = Date.new(params[:year].to_i, params[:month].to_i)
      finder = posts.published_between(@date, @date + 1.month)
    elsif params[:year]
      @date = Date.new(params[:year].to_i)
      finder = posts.published_between(@date, @date + 1.year)
    end

    @blog_posts = finder.all(:limit => 25, :order => "published_at desc")
    raise ActiveRecord::RecordNotFound.new("No posts found") if @blog_posts.empty?

    if params[:category]
      @page_title = "#{params[:category]}"
    elsif params[:tag]
      @page_title = "Posts tagged with #{params[:tag]}"
    elsif params[:year] && params[:month] && params[:day]
      @page_title = "Posts from #{@date.to_s(:long)}"
    elsif params[:year] && params[:month]
      @page_title = "Posts from #{Date::MONTHNAMES[@date.month]} #{@date.year}"
    elsif params[:year]
      @page_title = "Posts from #{@date.year}"
    end
  end

  def inline_options
    {:inline => self.template}
  end

  def self.default_order
    "name"
  end

  def editable_by?(user)
    user.able_to?(:administrate) || !(group_ids & user.group_ids).empty?
  end

  def potential_authors
    groups.map(&:users).flatten.uniq
  end


  #-------------------------------------------------------------------------------------------------

  def name_for_path
    name.to_slug.gsub('-', '_')
  end

protected
  def after_create
    section = Section.find_by_name(name) || (
      section = Section.create!(
        :name => name,
        :path => "/#{name_for_path}",
        :parent_id => 1
      )
      section.groups << Group.find_by_code("cms-admin")
      section.groups << Group.find_by_code("guest")
      section.groups << Group.find_by_code("content-editor")
      section.save!
      section
    )

    page = Page.find_by_name(name) || Page.create!(
      :name => name,
      :path => "/#{name_for_path}",
      :section => section,
      :template_file_name => "default.html.erb",
      :hidden => true
    )
    page.create_connector(self, 'main')
    create_route(page, "#{name}: Posts In Day",      "/#{name_for_path}/:year/:month/:day")
    create_route(page, "#{name}: Posts In Month",    "/#{name_for_path}/:year/:month")
    create_route(page, "#{name}: Posts In Year",     "/#{name_for_path}/:year")
    create_route(page, "#{name}: Posts With Tag",    "/#{name_for_path}/tag/:tag")
    create_route(page, "#{name}: Posts In Category", "/#{name_for_path}/category/:category")

    page = Page.find_by_name(portlet_name = "#{name}: Post") || Page.create!(
      :name => portlet_name,
      :path => "/#{name_for_path}/post",
      :section => section,
      :template_file_name => "default.html.erb",
      :hidden => true)
    page.publish
    create_route(  page, portlet_name, "/#{name_for_path}/:year/:month/:day/:slug")
    create_portlet(page, portlet_name, BlogPostPortlet)

    # FIXME: This takes about 5 seconds to run, which is probably too long.
    # Solution: Disable PageRoute's after_save :reload_routes and add this to the end here:
    # ActionController::Routing::Routes.load!
  end

  def create_route(page, name, pattern)
    route = page.page_routes.build(:name => name, :pattern => pattern, :code => "")
    route.add_condition(:method, "get")
    route.add_requirement(:year,  '\d{4,}') if pattern.include?(":year")
    route.add_requirement(:month, '\d{2,}') if pattern.include?(":month")
    route.add_requirement(:day,   '\d{2,}') if pattern.include?(":day")
    route.save!
  end

  def create_portlet(page, name, portlet_class)
    portlet_class.create!(
      :name => "#{name} Portlet",
      :blog_id => self.id,
      :template => portlet_class.default_template,
      :connect_to_page_id => page.id,
      :connect_to_container => "main",
      :publish_on_save => true)
  end
end
