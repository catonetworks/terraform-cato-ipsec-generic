resource "random_password" "shared_key_primary" {
  length  = 32
  special = true
}

resource "random_password" "shared_key_secondary" {
  length  = 32
  special = true
}

# Create Cato ipsec site and tunnels
resource "cato_ipsec_site" "ipsec-site" {
  name                 = var.site_name
  site_type            = var.site_type
  description          = var.site_description
  native_network_range = var.native_network_range
  site_location        = var.site_location
  
  lifecycle {
    precondition {
      condition     = !var.enable_bgp || var.peer_networks == null
      error_message = "peer_networks cannot be set when enable_bgp is true. Use BGP routing instead."
    }
    precondition {
      condition     = var.enable_bgp || var.peer_networks != null
      error_message = "peer_networks must be set when enable_bgp is false."
    }
    precondition {
      condition     = !var.enable_bgp || (var.primary_private_cato_ip != null && var.primary_private_site_ip != null)
      error_message = "primary_private_cato_ip and primary_private_site_ip are required when enable_bgp is true."
    }
    precondition {
      condition     = !var.enable_bgp || !var.ha_tunnels || (var.secondary_private_cato_ip != null && var.secondary_private_site_ip != null)
      error_message = "secondary_private_cato_ip and secondary_private_site_ip are required when enable_bgp is true and ha_tunnels is enabled."
    }
  }
  
  ipsec = {
    connection_mode     = var.cato_connectionMode
    identification_type = var.cato_identificationType
    init_message = {
      cipher    = var.cato_initMessage_cipher
      dh_group  = var.cato_initMessage_dhGroup
      integrity = var.cato_initMessage_integrity
      prf       = var.cato_initMessage_prf
    }
    auth_message = {
      cipher    = var.cato_authMessage_cipher
      dh_group  = var.cato_authMessage_dhGroup
      integrity = var.cato_authMessage_integrity
    }
    network_ranges = var.enable_bgp ? null : var.peer_networks
    primary = {
      destination_type  = var.primary_destination_type
      public_cato_ip_id = data.cato_allocatedIp.primary[0].items[0].id
      pop_location_id   = var.primary_pop_location_id
      tunnels = [
        {
          public_site_ip  = var.peer_primary_public_ip
          private_cato_ip = var.enable_bgp ? var.primary_private_cato_ip : null
          private_site_ip = var.enable_bgp ? var.primary_private_site_ip : null
          psk = var.primary_connection_shared_key == null ? random_password.shared_key_primary.result : var.primary_connection_shared_key
          last_mile_bw = {
            downstream = var.downstream_bw
            upstream   = var.upstream_bw
          }
        }
      ]
    }
    secondary = var.ha_tunnels ? {
      destination_type  = var.secondary_destination_type
      public_cato_ip_id = var.ha_tunnels ? data.cato_allocatedIp.secondary[0].items[0].id : null
      pop_location_id   = var.secondary_pop_location_id
      tunnels = [
        {
          public_site_ip  = var.peer_secondary_public_ip
          private_cato_ip = var.enable_bgp ? var.secondary_private_cato_ip : null
          private_site_ip = var.enable_bgp ? var.secondary_private_site_ip : null
          psk             = var.secondary_connection_shared_key == null ? random_password.shared_key_secondary.result : var.secondary_connection_shared_key
          last_mile_bw = {
            downstream = var.downstream_bw
            upstream   = var.upstream_bw
          }
        }
      ]
    } : null
    
  }
}

# If BGP Enabled, build the BGP Configuration on the Cato Side.
resource "cato_bgp_peer" "primary" {
  count                    = var.enable_bgp ? 1 : 0
  site_id                  = cato_ipsec_site.ipsec-site.id
  name                     = var.cato_primary_bgp_peer_name == null ? "${var.site_name}-primary-bgp-peer" : var.cato_primary_bgp_peer_name
  cato_asn                 = var.cato_bgp_asn
  peer_asn                 = var.peer_bgp_asn
  peer_ip                  = var.primary_private_site_ip
  metric                   = var.cato_primary_bgp_metric
  default_action           = var.cato_primary_bgp_default_action
  advertise_all_routes     = var.cato_primary_bgp_advertise_all
  advertise_default_route  = var.cato_primary_bgp_advertise_default_route
  advertise_summary_routes = var.cato_primary_bgp_advertise_summary_route
  md5_auth_key             = "" #Inserting Blank Value to Avoid State Changes 

  bfd_settings = {
    transmit_interval = var.cato_primary_bgp_bfd_transmit_interval
    receive_interval  = var.cato_primary_bgp_bfd_receive_interval
    multiplier        = var.cato_primary_bgp_bfd_multiplier
  }
  # Inserting Ignore to avoid API and TF Fighting over a Null Value 
  lifecycle {
    ignore_changes = [
      summary_route
    ]
  }
}

resource "cato_bgp_peer" "backup" {
  count                    = var.enable_bgp && var.ha_tunnels ? 1 : 0
  site_id                  = cato_ipsec_site.ipsec-site.id
  name                     = var.cato_secondary_bgp_peer_name == null ? "${var.site_name}-secondary-bgp-peer" : var.cato_secondary_bgp_peer_name
  cato_asn                 = var.cato_bgp_asn
  peer_asn                 = var.peer_bgp_asn
  peer_ip                  = var.secondary_private_site_ip
  metric                   = var.cato_secondary_bgp_metric
  default_action           = var.cato_secondary_bgp_default_action
  advertise_all_routes     = var.cato_secondary_bgp_advertise_all
  advertise_default_route  = var.cato_secondary_bgp_advertise_default_route
  advertise_summary_routes = var.cato_secondary_bgp_advertise_summary_route
  md5_auth_key             = "" #Inserting Blank Value to Avoid State Changes 

  bfd_settings = {
    transmit_interval = var.cato_secondary_bgp_bfd_transmit_interval
    receive_interval  = var.cato_secondary_bgp_bfd_receive_interval
    multiplier        = var.cato_secondary_bgp_bfd_multiplier
  }

  lifecycle {
    ignore_changes = [
      summary_route
    ]
  }
}

resource "cato_license" "license" {
  depends_on = [cato_ipsec_site.ipsec-site]
  count      = var.license_id == null ? 0 : 1
  site_id    = cato_ipsec_site.ipsec-site.id
  license_id = var.license_id
  bw         = var.license_bw == null ? null : var.license_bw
}
