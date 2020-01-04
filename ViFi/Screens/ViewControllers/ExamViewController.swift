//
//  ExamViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase
import GoogleMobileAds

class ExamViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, GADRewardedAdDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var examName = String()
    var examType = String()
    var examsNameArray = [String]()
	var isAdvertising = Bool()
    var isShowedAd = Bool()
	
    var interstitial: GADInterstitial!
	var rewardedAd: GADRewardedAd?

    @IBOutlet weak var examTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        self.examTableView.delegate = self
        self.examTableView.dataSource = self
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    override func viewWillAppear(_ animated: Bool) {
		
		self.isShowedAd = false
		self.rewardedAd = createAndLoadRewardedAd()
        
        // test id ca-app-pub-3940256099942544/8691691433
        interstitial = GADInterstitial(adUnitID: "ca-app-pub-9037305793844471/3698836274") // id değeri atandı.
        let request = GADRequest() // request olusturma
        interstitial.load(request) // reklamı yüklemek için isteği ekledik.
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        tabBar.tabbarItem.isHidden = true
        
        examsNameArray.removeAll()
        
        getDataFromFireBase()
    }
	
	func createAndLoadRewardedAd() -> GADRewardedAd {
		self.rewardedAd = GADRewardedAd(adUnitID: "ca-app-pub-9037305793844471/3856324039")
		self.rewardedAd?.load(GADRequest()) { error in
		if let error = error {
		  print("Loading failed: \(error)")
		} else {
		  print("Loading Succeeded")
		}
	  }
		return self.rewardedAd!
	}
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universitiess").child(uniName).child(facName).child(depName).child(lessonName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "lessonname" ) {
                self.examsNameArray.append(snapshot.key)
            }
            self.examTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.examsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		if (indexPath.row < 3) {
			let cell = examTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! ExamTableViewCell
			if examsNameArray.count != 0 {
				cell.examNameLabel.text = "Görmek için lütfen reklamı izleyiniz."
			}
			return cell
		} else {
			let cell = examTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! ExamTableViewCell
			if examsNameArray.count != 0 {
				cell.examNameLabel.text = examsNameArray[indexPath.row]
			}
			return cell
		}
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		if (indexPath.row < 3) {
			self.isAdvertising = true
			examName = examsNameArray[indexPath.row]
			self.advertisingRewardedAdMethod()
		} else {
			self.isAdvertising = false
			examName = examsNameArray[indexPath.row]
		}
    }
    
    func getDataFromFireBaseExamType() {
        let dataBaseRefence = Database.database().reference()
        dataBaseRefence.child("Universitiess").child(uniName).child(facName).child(depName).child(lessonName).child(examName).observe(DataEventType.childAdded) { (snapshot) in
            
            if (snapshot.key != "imagename" ) {
                self.examType = snapshot.key
                
                if (self.examType == "PDF") {
                    self.performSegue(withIdentifier: "toPDFVC", sender: nil)
                }
                
                if (self.examType == "JPG") {
                    self.performSegue(withIdentifier: "toJPGVC", sender: nil)
                }
            }
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "toJPGVC" {
            let destinationVC = segue.destination as! JPGViewController
            destinationVC.lessonName = self.lessonName
            destinationVC.examName = self.examName
            destinationVC.examType = self.examType
        }
        if segue.identifier == "toPDFVC" {
            let destinationVC = segue.destination as! PDFViewController
            destinationVC.lessonName = self.lessonName
            destinationVC.examName = self.examName
        }
		self.advertisingMethod()
    }
	
	func advertisingMethod() {
		if (!isAdvertising) {
			if interstitial.isReady{ // reklam hazır
				interstitial.present(fromRootViewController: self) // reklamı aynı ekranda göster.
			} else { // reklam hazır değilse
				print("Reklam hazır değil") // consol'da mesaj bastırılacak.
			}
		}
	}
	
	func advertisingRewardedAdMethod() {
		if rewardedAd?.isReady == true {
			rewardedAd?.present(fromRootViewController: self, delegate:self)
		} else {
			self.rewardedAd = createAndLoadRewardedAd()
		}
	}
	
	func rewardedAd(_ rewardedAd: GADRewardedAd, userDidEarn reward: GADAdReward) {
		self.isShowedAd = true
	}
	
	func rewardedAdDidDismiss(_ rewardedAd: GADRewardedAd) {
		self.rewardedAd = createAndLoadRewardedAd()
		if (self.isShowedAd) {
			getDataFromFireBaseExamType()
		}
	}
	
	func rewardedAd(_ rewardedAd: GADRewardedAd, didFailToPresentWithError error: Error) {
		print("Rewarded ad failed to present.")
		self.rewardedAd = createAndLoadRewardedAd()
		self.advertisingRewardedAdMethod()
	}
}
