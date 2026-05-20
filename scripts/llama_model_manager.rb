#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'etc'

# Llama model orchestrator for llama.cpp server.
# Features:
# - Reads model definitions from ~/.config/llama/models as YAML/JSON, Modelfiles, or presets.ini
# - Supports defaults.yml, overrides.yml, plus hardware-aware overrides
# - Auto-loads matching models and unloads idle models
class LlamaModelManager
  DEFAULTS = {
    'models_root' => File.expand_path('~/.config/llama/models'),
    'defaults_file' => 'defaults.yml',
    'overrides_file' => 'overrides.yml',
    'server_url' => 'http://127.0.0.1:8080',
    'idle_timeout_seconds' => 120,
    'poll_interval_seconds' => 5,
    'autoload' => true,
    'match' => { 'autoload_tags' => [] },
    'hardware' => {
      'detect_gpu' => true,
      'vram_gb' => nil,
      'ram_gb' => nil
    }
  }.freeze

  def initialize(config = {})
    @config = deep_merge(DEFAULTS, stringify_keys(config || {}))
    @last_used = {}
    @loaded = {}
  end

  def run
    loop do
      catalog = discover_models
      load_matches(catalog) if @config['autoload']
      unload_idle
      sleep @config['poll_interval_seconds']
    end
  end

  def discover_models
    root = @config['models_root']
    defaults = read_optional_config(File.join(root, @config['defaults_file']))
    overrides = read_optional_config(File.join(root, @config['overrides_file']))
    hw = detect_hardware

    entries = Dir.glob(File.join(root, '*')).sort.filter_map do |path|
      base = File.basename(path)
      next if base.start_with?('.')
      next if [@config['defaults_file'], @config['overrides_file']].include?(base)

      model = parse_model_definition(path)
      next unless model

      merged = deep_merge(defaults, model)
      per_model_override = (overrides['models'] || {})[merged['name']] || {}
      merged = deep_merge(merged, per_model_override)
      merged = deep_merge(merged, select_hardware_override(merged, hw))
      merged['runtime_hardware'] = hw
      merged
    end

    entries.each { |m| @last_used[m['name']] ||= Time.now }
    entries
  end

  private

  def load_matches(catalog)
    catalog.each do |model|
      next if @loaded[model['name']]
      next unless autoload_match?(model)

      if load_model(model)
        @last_used[model['name']] = Time.now
        @loaded[model['name']] = model
      end
    end
  end

  def unload_idle
    now = Time.now
    timeout = @config['idle_timeout_seconds']

    @loaded.keys.each do |name|
      idle = now - (@last_used[name] || now)
      next unless idle >= timeout

      unload_model(name)
      @loaded.delete(name)
    end
  end

  def autoload_match?(model)
    wanted_tags = @config.dig('match', 'autoload_tags') || []
    return true if wanted_tags.empty?

    model_tags = model['tags'] || []
    (wanted_tags - model_tags).empty?
  end

  def parse_model_definition(path)
    if File.directory?(path)
      parse_directory_model(path)
    elsif path.end_with?('.yml', '.yaml', '.json')
      parse_structured_file(path)
    elsif path.end_with?('.ini')
      parse_presets_ini(path)
    else
      parse_modelfile(path)
    end
  end

  def parse_directory_model(path)
    files = Dir.glob(File.join(path, '*'))
    structured = files.find { |f| f.end_with?('.yml', '.yaml', '.json') }
    return parse_structured_file(structured) if structured

    presets = files.find { |f| f.end_with?('.ini') }
    return parse_presets_ini(presets) if presets

    modelfile = files.find { |f| File.basename(f).downcase.include?('modelfile') }
    return parse_modelfile(modelfile) if modelfile

    nil
  end

  def parse_structured_file(path)
    data = if path.end_with?('.json')
             JSON.parse(File.read(path))
           else
             YAML.safe_load(File.read(path), aliases: true)
           end
    normalize_model(data, path)
  rescue StandardError => e
    warn "[llama-model-manager] parse error #{path}: #{e.message}"
    nil
  end

  def parse_presets_ini(path)
    sections = Hash.new { |h, k| h[k] = {} }
    current = nil
    File.readlines(path, chomp: true).each do |line|
      t = line.strip
      next if t.empty? || t.start_with?('#', ';')

      if t.start_with?('[') && t.end_with?(']')
        current = t[1..-2]
        next
      end

      key, val = t.split('=', 2).map { |x| x&.strip }
      next unless current && key && val

      sections[current][key] = cast_ini_value(val)
    end

    preset_name = File.basename(path).sub(/\.ini$/, '')
    normalize_model({ 'name' => preset_name, 'preset' => sections, 'tags' => ['preset'] }, path)
  rescue StandardError => e
    warn "[llama-model-manager] presets parse error #{path}: #{e.message}"
    nil
  end

  def parse_modelfile(path)
    model = { 'source' => path, 'params' => {}, 'tags' => [], 'speculative' => {} }
    File.readlines(path, chomp: true).each do |line|
      s = line.strip
      next if s.empty? || s.start_with?('#')

      key, value = s.split(/\s+/, 2)
      next unless key

      case key.upcase
      when 'FROM' then model['model'] = value
      when 'NAME' then model['name'] = value
      when 'SYSTEM' then model['system'] = value
      when 'TEMPLATE' then model['template'] = value
      when 'PARAMETER'
        p_key, p_val = value.to_s.split(/\s+/, 2)
        model['params'][p_key] = p_val
      when 'TAG' then model['tags'] << value
      when 'SPECULATIVE_MODEL' then model['speculative']['model'] = value
      when 'SPECULATIVE_MAX' then model['speculative']['max_draft'] = value.to_i
      when 'SPECULATIVE_MIN' then model['speculative']['min_draft'] = value.to_i
      end
    end
    model['name'] ||= File.basename(path).sub(/\..+$/, '')
    normalize_model(model, path)
  rescue StandardError => e
    warn "[llama-model-manager] modelfile parse error #{path}: #{e.message}"
    nil
  end

  def normalize_model(data, path)
    return nil unless data.is_a?(Hash)

    model = stringify_keys(data)
    model['source'] ||= path
    model['name'] ||= File.basename(path).sub(/\..+$/, '')
    model['params'] ||= {}
    model['tags'] ||= []
    model
  end

  def load_model(model)
    payload = {
      action: 'load',
      name: model['name'],
      model: model['model'],
      preset: model['preset'],
      chat_template: model['template'],
      system_prompt: model['system'],
      params: model['params'],
      speculative: model['speculative']
    }.compact

    post('/slots', payload)
  end

  def unload_model(name)
    post('/slots', { action: 'unload', name: name })
  end

  def post(path, body)
    uri = URI.join(@config['server_url'], path)
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req.body = JSON.dump(body)

    Net::HTTP.start(uri.host, uri.port) do |http|
      resp = http.request(req)
      return true if resp.code.to_i.between?(200, 299)

      warn "[llama-model-manager] #{path} failed #{resp.code}: #{resp.body}"
      false
    end
  rescue StandardError => e
    warn "[llama-model-manager] request failed #{path}: #{e.message}"
    false
  end

  def read_optional_config(path)
    return {} unless File.exist?(path)

    data = YAML.safe_load(File.read(path), aliases: true) || {}
    stringify_keys(data)
  rescue StandardError => e
    warn "[llama-model-manager] config read error #{path}: #{e.message}"
    {}
  end

  def detect_hardware
    hw_cfg = @config['hardware'] || {}
    return { 'vram_gb' => hw_cfg['vram_gb'], 'ram_gb' => hw_cfg['ram_gb'], 'gpu' => 'manual' } unless hw_cfg['detect_gpu']

    {
      'vram_gb' => detect_vram_gb || hw_cfg['vram_gb'],
      'ram_gb' => detect_ram_gb || hw_cfg['ram_gb'],
      'gpu' => detect_gpu_name
    }
  end

  def select_hardware_override(model, hw)
    rules = model['hardware_overrides'] || {}
    vram = hw['vram_gb']&.to_f
    return {} unless vram

    candidates = rules.select do |k, _|
      m = k.match(/vram_(\d+)(?:_(\d+))?/)
      next false unless m
      lo = m[1].to_f
      hi = (m[2] || '1000').to_f
      vram >= lo && vram <= hi
    end
    return {} if candidates.empty?

    _, override = candidates.max_by { |k, _| k.split('_')[1].to_f }
    stringify_keys(override || {})
  end

  def detect_gpu_name
    out = `nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null`.strip
    return out.lines.first&.strip unless out.empty?

    rocm = `rocminfo 2>/dev/null | awk -F': ' '/Marketing Name/ {print $2; exit}'`.strip
    return rocm unless rocm.empty?

    'unknown'
  rescue StandardError
    'unknown'
  end

  def detect_vram_gb
    out = `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null`.strip
    unless out.empty?
      mib = out.lines.first.to_f
      return (mib / 1024.0).round(1)
    end

    nil
  rescue StandardError
    nil
  end

  def detect_ram_gb
    (Etc.sysconf(Etc::SC_PHYS_PAGES) * Etc.sysconf(Etc::SC_PAGE_SIZE) / 1024.0 / 1024 / 1024).round(1)
  rescue StandardError
    nil
  end

  def deep_merge(a, b)
    return a unless b.is_a?(Hash)

    merged = stringify_keys(a || {})
    stringify_keys(b).each do |k, v|
      merged[k] = merged[k].is_a?(Hash) && v.is_a?(Hash) ? deep_merge(merged[k], v) : v
    end
    merged
  end

  def stringify_keys(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_keys(v) }
    when Array
      value.map { |x| stringify_keys(x) }
    else
      value
    end
  end

  def cast_ini_value(v)
    return true if v == 'true'
    return false if v == 'false'
    return v.to_i if v.match?(/\A-?\d+\z/)
    return v.to_f if v.match?(/\A-?\d+\.\d+\z/)

    v
  end
end

if $PROGRAM_NAME == __FILE__
  config_path = ARGV[0]
  config = config_path && File.exist?(config_path) ? YAML.safe_load(File.read(config_path), aliases: true) : {}
  LlamaModelManager.new(config || {}).run
end
