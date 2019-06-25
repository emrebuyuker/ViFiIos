//
//  LessonViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase
import GoogleMobileAds

class LessonViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var lessonsNameArray = [String]()
    
    var interstitial: GADInterstitial!
    
    @IBOutlet weak var lessonTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.lessonTableView.delegate = self
        self.lessonTableView.dataSource = self
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    override func viewWillAppear(_ animated: Bool) {
        
        // test id ca-app-pub-3940256099942544/8691691433
        interstitial = GADInterstitial(adUnitID: "ca-app-pub-3940256099942544/8691691433") // id değeri atandı.
        let request = GADRequest() // request olusturma
        interstitial.load(request) // reklamı yüklemek için isteği ekledik.
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        lessonsNameArray.removeAll()
        
        getDataFromFireBase()
    }
    
    @IBAction func HomaButtonClick(_ sender: Any) {
        self.tabBarController?.selectedIndex = 0
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universities").child(uniName).child(facName).child(depName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "bolname" ) {
                self.lessonsNameArray.append(snapshot.key)
            }
            self.lessonTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.lessonsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = lessonTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! LessonTableViewCell
        if lessonsNameArray.count != 0 {
            cell.lessonNameLabel.text = lessonsNameArray[indexPath.row]
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        lessonName = lessonsNameArray[indexPath.row]
        performSegue(withIdentifier: "toExamVC", sender: nil)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "toExamVC" {
            let destinationVC = segue.destination as! ExamViewController
            destinationVC.lessonName = self.lessonName
            
            if interstitial.isReady{ // reklam hazır
                interstitial.present(fromRootViewController: self) // reklamı aynı ekranda göster.
            }else{ // reklam hazır değilse
                print("Reklam hazır değil") // consol'da mesaj bastırılacak.
            }
        }
    }
}
