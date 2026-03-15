# Mercury Messaging
<img width="2458" alt="Git Banner" src="https://github.com/user-attachments/assets/ce069091-71ee-4471-b2a3-4e1267d651e8">
<br></br>


Mercury is an open-source Telegram client designed specifically for the Apple Watch. It delivers a native and standalone experience, allowing you to send and receive Telegram messages directly from your wrist without relying on your iPhone. 
More info available [here](https://alessandro-alberti.notion.site/mercury).


<a href="https://testflight.apple.com/join/dCndzeB1">
  <img src="https://github.com/user-attachments/assets/86f3a622-ed56-485e-8572-b046c56d64bf" alt="Download on TestFlight" width="180">
</a>


## Main Features

### **Privacy-Focused and Open-Source**
Mercury’s code is fully open-source, so anyone can verify it handles user data responsibly and transparently.

### **True Standalone Experience**
Enjoy Telegram on your Apple Watch without needing an iPhone. Mercury works independently, so you stay connected wherever you are.

### **Modern Design, Cutting-Edge Technology**
Built with the latest Apple technologies and APIs, including Liquid Glass on watchOS 26, Mercury delivers a sleek, intuitive design for a seamless user experience.

### **Messaging**
- Send and receive text messages in real time
- Voice notes with waveform visualization and OGG Opus conversion
- Send and view photos with captions
- Watch videos, GIFs, and video notes inline with native playback
- Browse and send stickers (static WebP and animated Lottie)
- Emoji reactions on any message
- Reply to specific messages
- Share messages, photos, videos, and locations to Messages, Mail, and more via the system share sheet
- View message info (sender, date, forward origin, view/forward counts)
- Delete messages (for yourself or for everyone)

### **Secret Chats**
- End-to-end encrypted messaging via Telegram's secret chat protocol
- Start a secret chat from the compose menu (lock icon)
- Green lock indicator on secret chat titles in the chat list and chat detail
- Key exchange status banner during setup
- All encryption handled by TDLib — messages never touch Telegram's servers
- Note: Secret chats are device-specific (same as Telegram Desktop)

### **Location Sharing**
- Send your current GPS location directly from the Watch
- View received locations and venues on an interactive map

### **Contacts and New Chats**
- Start new conversations from a searchable contact list
- Create private chats with any Telegram contact

### **Chat Management**
- All chats, archived chats, and custom chat folders
- Pin and mute chats with swipe actions
- Read receipts and typing/recording indicators
- Unread message badges with mention and reaction indicators

### **Quick Replies and Smart Status**
- Bolt icon in chat toolbar for instant canned responses (OK, On my way, Call me, BRB, etc.)
- Smart status replies powered by 13 live watch data sources — tap any to send as a message:
  - Workout status ("In a workout - Running 23min") — HealthKit
  - Calendar status ("Busy until 3pm - Team Meeting") — EventKit
  - Health stats ("Today: 8,432 steps | 340 cal | 72 bpm") — HealthKit
  - Now Playing ("Listening to: Bohemian Rhapsody - Queen") — MediaPlayer
  - Weather ("Weather: 72°F, Mostly Clear") — WeatherKit
  - Location ("Currently in San Francisco, CA") — CoreLocation
  - Sleep ("Slept 7h 23m last night") — HealthKit
  - Activity Rings ("Move: 420/500 cal | Exercise: 22/30 min | Stand: 8/12 hr") — HealthKit
  - Blood Oxygen ("Blood oxygen: 98%") — HealthKit
  - Noise Level ("Ambient noise: 45 dB") — HealthKit
  - Altitude ("Relative altitude: 1,200 ft") — CMAltimeter
  - Reminders ("Reminder: Buy groceries") — EventKit
  - Battery ("Watch battery: 45%") — WKInterfaceDevice

### **Search**
- Global search from the Home page — find chats by name and messages across all conversations
- In-chat search — search messages within the current conversation
- Results show sender, preview text, and date

### **Siri and Shortcuts**
- "Hey Siri, send a message on Mercury" — voice-driven messaging
- "Hey Siri, check my Mercury messages" — check unread count hands-free
- Siri Announce Messages — Siri reads incoming messages aloud via AirPods
- Full Shortcuts app integration for custom automations

### **Watch Face Complications**
- WidgetKit complications in circular, corner, rectangular, and inline families
- Shows unread message count and last sender name
- Smart Stack relevance — widget surfaces automatically when messages are waiting
- Deep link to open the app directly from the complication

### **Notifications**
- Reply to messages directly from notification banners
- Mark as Read action without opening the app
- Tap notification to jump straight to the conversation
- APNs integration with Telegram’s push servers

### **Double Tap Gesture**
- On Apple Watch Series 9, Ultra 2, and later — double tap (pinch) to send a thumbs up to the last received message in the current chat

### **Account Settings**
- Edit your name and bio from the Watch
- View and manage active Telegram sessions (devices)
- Terminate sessions with a swipe

### **Profile and Moderation**
- View user profiles with avatar, username, and phone number
- Block and unblock users
- Report messages in group chats

### **Background Sync**
- Background App Refresh keeps unread counts synced every 15 minutes
- Messages are ready the instant you launch the app

### **Haptic Feedback**
- Distinct haptic patterns for new messages, mentions, reactions, and sent confirmations

### **Security**
- TDLib database encrypted at rest with Keychain-stored key
- NSFileProtection on sensitive directories
- Keychain-based credential storage
- Voice recordings cleaned up immediately after sending
- Release builds suppress sensitive logging
- Dependencies pinned to specific commit hashes for supply chain security
- Privacy manifest (PrivacyInfo.xcprivacy) included

## How to Build  

If you want to build the project yourself, you'll need to generate your own **Telegram API Hash** and **ID**. Follow these steps:  

1. **Generate Telegram API Credentials**  
   - Visit [this page](https://core.telegram.org/api/obtaining_api_id) to obtain your **API Hash** and **API ID**.  

2. **Modify the Secret Service File**  
   - Navigate to [`SecretService-sample.swift`](https://github.com/mercurytelegram/Mercury/blob/main/Mercury%20Watch%20App/Utils/Services/SecretService-sample.swift).  
   - Rename the `SecretService_Sample` enum to `SecretService`.  

3. **Add Your Credentials**  
   - Insert the **API Hash** and **API ID** you obtained in Step 1 into the `static` properties of the `SecretService` enum.  

4. **Build and Run**  
   - You're all set! Build and run the project in Xcode. 🚀

## Contributing

Contributions are welcome! Feel free to submit issues or pull requests to make **Mercury for Telegram** even better!

The features changelog is available [here](https://alessandro-alberti.notion.site/mercury-changelog).

## Contact  

Feel free to reach out to us on Telegram:  
- **Alessandro Alberti**: [@AlessandroAlberti](https://t.me/AlessandroAlberti)  
- **Marco Tammaro**: [@MarcoTammaro](https://t.me/MarcoTammaro)  


