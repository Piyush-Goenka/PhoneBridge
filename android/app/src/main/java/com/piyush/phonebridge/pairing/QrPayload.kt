package com.piyush.phonebridge.pairing

import org.json.JSONException
import org.json.JSONObject

data class QrPayload(
    val host: String,
    val port: Int,
    val token: String,
    val fingerprint: String,
) {
    companion object {
        fun parse(json: String): QrPayload? = try {
            val obj = JSONObject(json)
            if (obj.getInt("v") != 1) null
            else QrPayload(
                host = obj.getString("host"),
                port = obj.getInt("port"),
                token = obj.getString("token"),
                fingerprint = obj.getString("fp").lowercase(),
            )
        } catch (e: JSONException) {
            null
        }
    }
}
