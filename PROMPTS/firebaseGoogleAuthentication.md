# Goal: Recreate the Sign-In method using Google Authentication

## Prerequisites
* Read SPEC.md in the project root folder, this is the main identity of the project as a whole
* Read RULES.md, these are the coding rules and standards you must follow whenever you are editing or working on the project
* Read LOGS.md, this is where the changes made and updates to the project is being documented

## Task: Fix the Google Authentication method
* The current sign-in method does not work, it will automatically lets users use the app without saving their profile and accounts on a firebase database
* Combine the firebase database from the exisiting FloodSight Website Dashboard so that both the mobile app and website use the same database
* Find a way to connect the mobile app to the firebase database
## Description and Context
The FloodSight Website Dashboard's sign in method works via Google Auth. There is no other sign-in method in the dashboard, only the Google Auth is the sign-in method. I want the Mobile Application to have the same sign-in method but no firebase is currently attached to the app. 

This is the current Firebase environment information. Store these values in `.env` rather than committing real credentials.
FIREBASE_API_KEY=<your firebase api key>
FIREBASE_AUTH_DOMAIN=floodsight-flood-monitoring.firebaseapp.com
FIREBASE_PROJECT_ID=floodsight-flood-monitoring
FIREBASE_STORAGE_BUCKET=floodsight-flood-monitoring.firebasestorage.app
FIREBASE_MESSAGING_SENDER_ID=<your firebase messaging sender id>
FIREBASE_APP_ID=<your firebase app id>

# MongoDB Atlas connection
MONGODB_URI=<your mongodb atlas uri>
MONGODB_DB=CCTVs
MONGODB_COLLECTION=cctv data

Use the available information given and try to ask me questions for further confirmation and clarification before editing the code