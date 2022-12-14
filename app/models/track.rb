# require 'polylines'
require "open-uri"
# require "nokogiri"
require "fast_polylines"
# require "down"

class Track < ApplicationRecord
  belongs_to :user
  has_many :gruppettos, dependent: :destroy

  has_one_attached :file, service: :cloudinary_raw, dependent: :destroy
  has_one_attached :image, dependent: :destroy

  geocoded_by :address
  after_validation :geocode, if: :will_save_change_to_address?

  validates :name, presence: true
  validate :validate_file_filetypes

  after_commit :async_map_data, on: :create

  # after_commit :broadcast_change

  def async_map_data
    TrackDataJob.perform_later(self)
  end

  def update_map_data
    load_coordinates
    create_track_image
    # create_geojson
    # inform frontend about new data via ActionCable
    broadcast_change
  end

  def broadcast_change
    sleep 1.5
    # debugger
    TracksChannel.broadcast_to(
      self,
      {
        totalKm: total_km,
        totalVm: total_vm,
        trackImage: image.url
      }
    )
  end

  def load_coordinates
    if !file.key.nil?
      import_gpx
      calculate_distance
      calculate_vertical_meters
    elsif @address
      update(encoded_coordinates: encode_parameters([[lon, lat], [lon, lat]]))
    end
  end

  def create_track_image
    image_size = 300
    output = ERB::Util.url_encode(encoded_coordinates)
    output = ERB::Util.url_encode(shorten_output) if output.length >= 8000

    url = "https://api.mapbox.com/styles/v1/mapbox/dark-v10/static/path+37caa8(#{output})/auto/#{image_size}x#{image_size}?access_token=#{ENV.fetch('MAPBOX_API_KEY')}"

    file = Down.download(url)
    image.attach(io: file, filename: "track-#{id}.png", content_type: "image/png")
  end

  def create_geojson
    coords = decode_parameters(encoded_coordinates)
    geojson = "{'type': 'geojson','data': {'type': 'Feature','properties': {},'geometry': {'type': 'LineString','coordinates':#{coords}}}}"
    update(data_geojson: geojson)
  end

  def import_gpx
    @coordinates_array = []
    @elevations_array = []
    gpx_file = Down.download(file.attachment.blob.url)

    Nokogiri::XML(gpx_file).xpath('//xmlns:trkpt').each do |trkpt|
      lat = trkpt.xpath('@lat').to_s.to_f
      lon = trkpt.xpath('@lon').to_s.to_f
      @coordinates_array << [lat, lon]

      @elevations_array << trkpt.text.strip.to_f
    end
    update(encoded_coordinates: encode_parameters(@coordinates_array), encoded_elevations: @elevations_array.to_s, address: fetch_address)
  end

  def fetch_address
    object = Geocoder.search([@coordinates_array[0][0], @coordinates_array[0][1]])[0].data
    "#{object['address']['road']}, #{object['address']['city']}, #{object['address']['country']}"
  end

  def calculate_distance
    coords = decode_parameters(encoded_coordinates)
    km = 0.0

    coords.each_index do |index|
      km += Geocoder::Calculations.distance_between(coords[index], coords[index + 1]) unless index == coords.length - 1
    end
    update(total_km: km.round(1))
  end

  def calculate_vertical_meters
    elevations = encoded_elevations.split(',')
    elevations.map!(&:to_f)

    vd = 0.0
    vm = 0.0

    elevations.each_index do |index|
      vd = index < elevations.length - 1 ? elevations[(index + 1)] - elevations[index] : 0
      vm += vd if vd.positive?
    end

    update(total_vm: vm.round(1))
  end

  def encode_parameters(array)
    FastPolylines.encode(array, 5)
  end

  def decode_parameters(parameters)
    FastPolylines.decode(parameters, 5)
  end

  def shorten_output
    coords = decode_parameters(encoded_coordinates)
    shortened_coords = coords.each_slice(2).map(&:last)
    encode_parameters(shortened_coords)
  end

  def validate_file_filetypes
    return unless file.attached?

    errors.add(:file, 'must be a gpx-file') unless file.content_type == 'application/xml'
  end
end
